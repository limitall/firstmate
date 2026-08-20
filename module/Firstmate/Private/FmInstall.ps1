#requires -Version 7.0
# FmInstall.ps1 - the setup path and the environment doctor.
#
# This area answers one question: what has to be true on a bare Windows 11
# machine before the captain can run firstmate, and how does one command make it
# true without ever half-doing it.
#
# THREE RULES SHAPE EVERYTHING BELOW.
#
# 1. DETECT BEFORE MUTATE. Install-FmHome runs the hard-prerequisite checks
#    first and refuses the whole run if one fails, before a single directory or
#    file is written. A machine that cannot run firstmate is left exactly as it
#    was, with the reasons printed. That is the difference between "not
#    installed" (recoverable by reading one line) and "half installed"
#    (recoverable by knowing what the installer does).
#
# 2. IDEMPOTENT BY CONSTRUCTION, NOT BY LUCK. Every step is a converge, not an
#    append: directories are created only when absent, the profile wiring lives
#    inside one delimited block that is replaced wholesale, and the hook
#    registration rewrites exactly the three events this port owns. Running
#    setup twice produces byte-identical files, and the second run reports
#    'already' for every step. tests/FmInstall.Tests.ps1 pins that.
#
# 3. ONE MECHANISM PER JOB. A bare `Import-Module Firstmate` and a bare
#    `fm-doctor.ps1` are both achieved by ONE mechanism - a managed block in the
#    user's PowerShell profile that prepends the checkout's module/ to
#    PSModulePath and bin/ to PATH, and exports FM_HOME.
#
#    THAT BLOCK IS A CONVENIENCE, NOT THE FOUNDATION. It is loaded by an
#    interactive session and by nothing else - not by a herdr pane, a Claude
#    hook, or a dispatched worker. What makes the entry points work in those is
#    bin/fm-module-load.ps1 plus the home this area persists in
#    <RepoRoot>/.fm-home. See docs/windows-install.md, "Working without the
#    profile". The consequence here: absent profile wiring is a WARNING, and the
#    absent home pointer is what is reported as missing.
#
#    The rejected alternative was the Windows User environment variables
#    (`[Environment]::SetEnvironmentVariable(..., 'User')`). It reaches cmd.exe
#    too, but it is silently a no-op on non-Windows .NET, so the development
#    path would report success while doing nothing, and it cannot express
#    "prepend to whatever this session already has". The profile block behaves
#    identically on both platforms, needs no admin rights and no Developer Mode,
#    and re-running setup after moving the checkout fixes it. firstmate is driven
#    from PowerShell, so a PowerShell-session mechanism is the whole requirement.
#
# The module is NOT copied into a modules directory. It is used from the
# checkout, so `git pull` updates the installed firstmate and there is no second
# copy to drift.

Set-StrictMode -Version Latest

# --- layout -------------------------------------------------------------------

# The four directories a firstmate home is made of. Get-FmSessionPaths resolves
# the same four from the environment contract; this is the creation side of that
# same list, and the foundation area's Get-FmHomeLayout owns it when loaded.
$script:FmInstallHomeDirectories = @('config', 'data', 'projects', 'state')

# Delimiters of the managed profile block. Matched literally, so a profile the
# captain has edited around the block keeps every other line untouched.
$script:FmInstallProfileBeginMarker = '# >>> firstmate-win >>>'
$script:FmInstallProfileEndMarker = '# <<< firstmate-win <<<'

# The three Claude hook events this port owns. Everything else in a project's
# settings.json - other events, other top-level keys - is preserved verbatim.
$script:FmInstallOwnedHookEvents = @('SessionStart', 'PreToolUse', 'Stop')

# The checkout this module was loaded from. Every wiring path is derived from it
# rather than from the caller's cwd, so setup run from anywhere wires the
# checkout that is actually being installed.
function Get-FmInstallRepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # module/Firstmate/Private/<this file> -> the checkout is three levels up.
    (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..')).Path
}

# The four home directories as { Name; Path } records.
#
# PATHS, NOT NAMES, AND FROM THE OWNER. The foundation area's Get-FmHomeLayout
# is authoritative once loaded, and it honours FM_STATE_OVERRIDE and friends -
# so state/ can legitimately sit outside the home and only the owner knows
# where. Joining a name onto the home would quietly create the wrong directory
# and leave the real one missing.
#
# Get-FmHomeLayout returns ONE pscustomobject with Home/State/Data/Config/
# Projects properties. An earlier revision of this function treated its output
# as a list of directory names, which stringified the whole object into a single
# bogus name like '@{Root=...; Home=...}'. That passed every test for as long as
# the foundation area was unlanded and broke the moment it landed - the by-name
# binding hazard AGENTS.md describes. Hence the explicit per-property read, and
# the test that asserts the four leaf names.
function Get-FmInstallHomeDirectory {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $shared = Resolve-FmSessionCommand -Name 'Get-FmHomeLayout'
    if ($shared) {
        try {
            $layout = & $shared -HomePath $FirstmateHome
            $properties = @($layout.PSObject.Properties.Name)
            $records = @()
            foreach ($name in $script:FmInstallHomeDirectories) {
                $property = $name.Substring(0, 1).ToUpperInvariant() + $name.Substring(1)
                if ($properties -notcontains $property) { break }
                $path = [string]$layout.$property
                if ([string]::IsNullOrWhiteSpace($path)) { break }
                $records += [pscustomobject]@{ Name = $name; Path = $path }
            }
            # All four or none: a partial answer means the owner's shape is not
            # what this code was written against, and half a home is worse than
            # the local fallback.
            if ($records.Count -eq $script:FmInstallHomeDirectories.Count) { return $records }
            Write-Verbose 'Get-FmHomeLayout did not expose all four home directories; using the local layout.'
        } catch {
            Write-Verbose "Get-FmHomeLayout failed, using the local home layout: $_"
        }
    }
    return @($script:FmInstallHomeDirectories | ForEach-Object {
            [pscustomobject]@{ Name = $_; Path = (Join-Path -Path $FirstmateHome -ChildPath $_) }
        })
}

# WHERE A HOME LIVES WHEN THE CAPTAIN DOES NOT NAME ONE HAS ONE OWNER, AND IT IS
# NOT THIS FILE. Resolve-FmEntryPointHome answers it, and its tail is the
# CHECKOUT. This area used to keep a second copy of the same question that ended
# in <userprofile>/firstmate, which is how a fresh install ended up with the code
# in one directory and the home in another - a layout the Linux firstmate does
# not have, and one the documented workflow walks straight into. See
# Set-FmInstallHomeRedirect below for what happens when they ARE separate.

# --- the home that is not the checkout -------------------------------------------
#
# On Linux the two coincide: the firstmate repo root IS the home, with config/
# data/ projects/ state/ gitignored beside AGENTS.md, CLAUDE.md and .claude/. So
# `cd <firstmate>; claude` starts a session that has the instructions AND the
# hooks. Every doc in the fleet says to do exactly that.
#
# A Windows home that is separate from its checkout breaks that sentence
# SILENTLY: the directory exists, it looks like a firstmate home, and a session
# started in it has no AGENTS.md, no CLAUDE.md and no .claude/settings.json - so
# the agent comes up with no instructions, no digest and no supervision, and
# nothing anywhere says so. The captain hit this on the first command after
# installing.
#
# A separate home is still legitimate (a secondmate home, a home on another
# drive, a home shared with a Linux firstmate). So it is not refused - it is made
# to FAIL LOUDLY. Setup writes an AGENTS.md/CLAUDE.md into the home whose only
# job is to stop a session and name the checkout.
$script:FmInstallRedirectBeginMarker = '<!-- >>> firstmate-win home >>> -->'
$script:FmInstallRedirectEndMarker = '<!-- <<< firstmate-win home <<< -->'

function Test-FmInstallHomeIsCheckout {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    Test-FmPathEqual -Left $FirstmateHome -Right $RepoRoot
}

# Does this directory hold a firstmate checkout's OWN operating contract?
#
# The same two things Install-FmHome already demands of a -RepoRoot, plus the
# contract itself: module/Firstmate, and an AGENTS.md that is not already a
# redirect. A directory answering yes is a checkout somebody operates from, not
# a state directory - see Assert-FmInstallHomeIsNotCheckout for why that matters.
#
# AN EXISTING REDIRECT ANSWERS NO ON PURPOSE. A home setup has already redirected
# is a home setup may redirect again: converging the block it wrote itself
# rewrites nothing that was not already generated. Answering yes there would make
# the second run of an install refuse the first run's own work.
function Test-FmInstallPathHasOwnContract {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $module = Join-Path -Path $Path -ChildPath 'module' -AdditionalChildPath 'Firstmate'
    if (-not (Test-Path -LiteralPath $module -PathType Container)) { return $false }

    $agents = Join-Path -Path $Path -ChildPath 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) { return $false }
    $text = [System.IO.File]::ReadAllText($agents)
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return (-not $text.Contains($script:FmInstallRedirectBeginMarker))
}

# REFUSE TO WRITE THE REDIRECT INTO A CHECKOUT. The one shape the redirect must
# never meet, and the one it cannot tell apart from its own use case without
# being told to look.
#
# MEASURED, 2026-08-14. A run meaning only to repair a worker copy's skills link
# named one tree with -RepoRoot and the PRIMARY CHECKOUT with -FirstmateHome:
#
#   bin/fm-setup.ps1 -RepoRoot <worktree> -FirstmateHome <primary checkout> ...
#
# Set-FmInstallHomeRedirect concluded, correctly, that the home was not the
# checkout, and spliced its stop-and-redirect into the top of the primary's own
# 51,675-byte AGENTS.md - and into CLAUDE.md, which on a repaired checkout is the
# same file. The bytes below the block survived; what did not is the contract's
# FIRST instruction, which became "do no firstmate work from this directory" and
# named a disposable worktree. It was reported as one '[updated] home redirect'
# line among a dozen, and was recovered only because AGENTS.md is tracked in git.
#
# WHY REFUSAL AND NOT A CONFIRMATION. The redirect is correct for a home that
# holds only state, and it stays unconditional there - without it `cd <home>;
# claude` starts an agent with no instructions at all, which is the failure the
# redirect exists to prevent. But for a home that is itself a checkout there is
# no invocation this could be the right answer to: the caller who really means to
# set that checkout up says so with -RepoRoot, which is a shorter command AND
# leaves the contract alone. A prompt would only ask the captain to re-derive
# that at the moment they are least likely to - mid-install, one line among
# twelve. So the refusal names both the file and the invocation instead.
function Assert-FmInstallHomeIsNotCheckout {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    # The normal layout on this port: the home IS the checkout, as on Linux.
    # Nothing is redirected there, so there is nothing to refuse.
    if (Test-FmInstallHomeIsCheckout -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot) { return }
    if (-not (Test-FmInstallPathHasOwnContract -Path $FirstmateHome)) { return }

    $agents = Join-Path -Path $FirstmateHome -ChildPath 'AGENTS.md'
    throw (@(
            "error: the firstmate home '$FirstmateHome' is itself a firstmate-win checkout, with its own '$agents'."
            "       Setup writes a stop-and-redirect block at the TOP of a home's AGENTS.md and mirrors it to CLAUDE.md,"
            '       so this run would have overwritten the first thing every session in that checkout reads. Refusing;'
            '       nothing was written.'
            "       To set THAT checkout up, name it as the checkout: bin/fm-setup.ps1 -RepoRoot '$FirstmateHome'"
            "       To give '$RepoRoot' a separate home, name a directory that is not a checkout."
        ) -join "`n")
}

# The redirect's text. A pure function of the two paths, so two runs produce
# identical bytes and the second reports 'already' by comparing rather than
# guessing - the same converge-not-append rule as the profile block.
#
# It is written for BOTH readers. An agent reads the imperative; a human doing
# `dir` sees a file called CLAUDE.md and opens it to the same answer.
function Get-FmInstallHomeRedirect {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    @(
        $script:FmInstallRedirectBeginMarker
        '# STOP - this is a firstmate HOME, not the firstmate checkout'
        ''
        "This directory (``$FirstmateHome``) holds one instance's operational state -"
        '`config/ data/ projects/ state/` - and nothing else. It has no firstmate'
        'instructions and no Claude hooks, so a session started HERE comes up with no'
        'briefing, no startup digest and no supervision, and nothing else will tell you.'
        ''
        '**Start the session in the checkout instead:**'
        ''
        '```powershell'
        "cd $RepoRoot"
        'claude'
        '```'
        ''
        'The checkout has `AGENTS.md`, `.claude/settings.json` and `bin/`, and it reaches'
        'this home through `.fm-home`, so everything operates on the state you see here.'
        ''
        'If you are an agent reading this: do no firstmate work from this directory. Say'
        'the line above to the captain and stop.'
        ''
        '(On Linux the two are the same directory and this file does not exist. Managed by'
        'bin/fm-setup.ps1 - re-run setup to update it.)'
        $script:FmInstallRedirectEndMarker
    ) -join "`n"
}

# Splice the redirect into <home>/AGENTS.md, and mirror it to CLAUDE.md.
#
# BOTH NAMES, IDENTICAL BYTES. AGENTS.md is the real file by the repo's
# convention and CLAUDE.md is the name a Claude session looks for, and a session
# that reads only one of them must still be stopped. Set-FmAgentsMemory owns the
# symlink/hardlink/copy machinery for a PROJECT worktree; a copy is used here on
# purpose - this file is generated and never hand-edited, so a link buys nothing
# and cannot dangle, and that area already treats a byte-identical real CLAUDE.md
# on Windows as a materialized link rather than a conflict.
#
# Text outside the markers is preserved, so a home that is also a real repo keeps
# its own memory file.
function Set-FmInstallHomeRedirect {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (Test-FmInstallHomeIsCheckout -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot) {
        return [pscustomobject]@{
            Action = 'already'
            Detail = 'the home IS the checkout, as on Linux; nothing to redirect'
        }
    }

    # The guard belongs to the destructive act, not only to its caller.
    # Install-FmHome asserts this at its own gate so that a refused run has
    # written nothing at all; repeating it here is what keeps a second caller
    # from reintroducing the overwrite in silence.
    Assert-FmInstallHomeIsNotCheckout -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot

    $block = Get-FmInstallHomeRedirect -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot
    $agents = Join-Path $FirstmateHome 'AGENTS.md'
    $claude = Join-Path $FirstmateHome 'CLAUDE.md'
    $pattern = '(?s)' + [regex]::Escape($script:FmInstallRedirectBeginMarker) + '.*?' +
        [regex]::Escape($script:FmInstallRedirectEndMarker)

    $existing = ''
    if (Test-Path -LiteralPath $agents -PathType Leaf) { $existing = [System.IO.File]::ReadAllText($agents) }
    $match = [regex]::Match($existing, $pattern)

    if ($match.Success) {
        $updated = $existing.Remove($match.Index, $match.Length).Insert($match.Index, $block)
        $action = 'updated'
    } else {
        # The redirect goes FIRST. An agent that reads only the top of a long
        # file must still hit the stop.
        $separator = if ([string]::IsNullOrEmpty($existing)) { '' } else { "`n`n" }
        $updated = $block + "`n" + $separator + $existing
        $action = if ([string]::IsNullOrEmpty($existing)) { 'created' } else { 'updated' }
    }

    $claudeCurrent = ''
    if (Test-Path -LiteralPath $claude -PathType Leaf) { $claudeCurrent = [System.IO.File]::ReadAllText($claude) }
    if ($match.Success -and $updated -eq $existing -and $claudeCurrent -eq $updated) {
        return [pscustomobject]@{ Action = 'already'; Detail = "$agents (and CLAUDE.md) redirect to $RepoRoot" }
    }

    if (-not $PSCmdlet.ShouldProcess($FirstmateHome, 'write the firstmate home redirect')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }
    Write-FmTextFileLf -Path $agents -Text $updated
    Write-FmTextFileLf -Path $claude -Text $updated
    [pscustomobject]@{ Action = $action; Detail = "$agents (and CLAUDE.md) redirect to $RepoRoot" }
}

# The checkout's OWN memory files. Recorded here because it is the other half of
# "which directory do I start Claude in": making the home the checkout is no use
# if the checkout's CLAUDE.md is the 9-byte string "AGENTS.md" that git leaves
# when core.symlinks is false, which is the default on Windows and is MEASURED to
# be what the captain's clone contains.
#
# Set-FmAgentsMemory owns this rule; this only calls it, through the by-name seam
# so an absent owner is reported as a step that did NOT run rather than as one
# that passed.
function Set-FmInstallCheckoutMemory {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $owner = Resolve-FmSessionCommand -Name 'Set-FmAgentsMemory'
    if (-not $owner) {
        return [pscustomobject]@{
            Action = 'skipped'
            Detail = 'NOT RUN: the agent-memory area (Set-FmAgentsMemory) is not loaded'
        }
    }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'ensure AGENTS.md and CLAUDE.md')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }
    try {
        # -Path only. A by-name call may pass ONLY parameters the owner declares
        # (tests/FmModuleAssembly.Tests.ps1 enforces that), and the ShouldProcess
        # gate above already covers what -Confirm:$false was doing here.
        $result = & $owner -Path $RepoRoot
    } catch {
        # A conflict is the captain's to reconcile - two real, different memory
        # files. Setup says so and carries on; it must not clobber either.
        return [pscustomobject]@{ Action = 'skipped'; Detail = "NOT RUN: $($_.Exception.Message)" }
    }
    if (-not $result) { return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' } }
    $action = if ($result.Action -eq 'unchanged') { 'already' } elseif ($result.Action -eq 'created') { 'created' } else { 'updated' }
    [pscustomobject]@{ Action = $action; Detail = $result.Message }
}

# The OTHER committed symlink. CLAUDE.md is only half the instruction surface:
# .claude/skills points at .agents/skills, and a core.symlinks=false clone
# writes a 17-byte text file there too. The result is worse than the CLAUDE.md
# case, not better - every command works, the contract loads, and the session
# has ZERO skills with nothing anywhere saying so.
#
# Called through the by-name seam like the memory repair above, so an absent
# owner is reported as a step that did NOT run rather than as one that passed.
function Set-FmInstallSkillsLink {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $owner = Resolve-FmSessionCommand -Name 'Set-FmClaudeSkillsLink'
    if (-not $owner) {
        return [pscustomobject]@{
            Action = 'skipped'
            Detail = 'NOT RUN: the instruction-surface area (Set-FmClaudeSkillsLink) is not loaded'
        }
    }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'link .claude/skills to .agents/skills')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }
    try {
        # -RepoRoot only: a by-name call may pass ONLY parameters the owner
        # declares, and the ShouldProcess gate above already covers the rest.
        $result = & $owner -RepoRoot $RepoRoot
    } catch {
        return [pscustomobject]@{ Action = 'skipped'; Detail = "NOT RUN: $($_.Exception.Message)" }
    }
    if (-not $result) { return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' } }
    [pscustomobject]@{ Action = $result.Action; Detail = $result.Detail }
}

function Test-FmInstallHomeRedirectCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $block = Get-FmInstallHomeRedirect -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot
    foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
        $path = Join-Path $FirstmateHome $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if (-not ([System.IO.File]::ReadAllText($path).Contains($block))) { return $false }
    }
    return $true
}

# --- step records --------------------------------------------------------------
#
# Both halves of this area report the same way: a flat list of records that a
# formatter turns into lines. Install-FmHome emits Action records ('created',
# 'already', 'updated', 'skipped'), Invoke-FmDoctor emits Status records
# ('ok', 'warn', 'missing'). Keeping them separate matters: a doctor check that
# did not run must never be printed as one that passed.

# A record constructor, not a state change - the analyzer reads the verb only.
function New-FmInstallStep {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; nothing outside the pipeline changes.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('created', 'already', 'updated', 'skipped')][string]$Action,
        [string]$Detail = ''
    )
    [pscustomobject]@{ Name = $Name; Action = $Action; Detail = $Detail }
}

function New-FmInstallCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; nothing outside the pipeline changes.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'missing')][string]$Status,
        [string]$Detail = '',
        [string]$Fix = '',
        [switch]$Required
    )
    [pscustomobject]@{
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Fix      = $Fix
        Required = [bool]$Required
    }
}

function Format-FmInstallCheckLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Check)

    $lines = @("  [$($Check.Status)]".PadRight(12) + $Check.Name + $(if ($Check.Detail) { " - $($Check.Detail)" } else { '' }))
    if ($Check.Status -ne 'ok' -and $Check.Fix) { $lines += ('              fix: ' + $Check.Fix) }
    $lines
}

function Format-FmInstallStepLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Step)

    "  [$($Step.Action)]".PadRight(12) + $Step.Name + $(if ($Step.Detail) { " - $($Step.Detail)" } else { '' })
}

# --- the home layout ------------------------------------------------------------

function New-FmInstallHomeLayout {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    if (-not $PSCmdlet.ShouldProcess($FirstmateHome, 'create the firstmate home layout')) { return @() }

    $steps = @()
    if (Test-Path -LiteralPath $FirstmateHome -PathType Container) {
        $steps += New-FmInstallStep -Name 'home' -Action 'already' -Detail $FirstmateHome
    } else {
        if (Test-Path -LiteralPath $FirstmateHome) {
            throw "error: firstmate home '$FirstmateHome' exists but is not a directory; refusing to install over it"
        }
        $null = New-Item -ItemType Directory -Path $FirstmateHome -Force
        $steps += New-FmInstallStep -Name 'home' -Action 'created' -Detail $FirstmateHome
    }

    foreach ($entry in (Get-FmInstallHomeDirectory -FirstmateHome $FirstmateHome)) {
        $name = $entry.Name
        $dir = $entry.Path
        # Name the path whenever an override has moved it out of the home, so
        # "home/state" never silently means somewhere else.
        $detail = if ((Join-Path -Path $FirstmateHome -ChildPath $name) -eq $dir) { '' } else { $dir }
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $steps += New-FmInstallStep -Name "home/$name" -Action 'already' -Detail $detail
            continue
        }
        if (Test-Path -LiteralPath $dir) {
            throw "error: '$dir' exists but is not a directory; refusing to install over it"
        }
        $null = New-Item -ItemType Directory -Path $dir -Force
        $steps += New-FmInstallStep -Name "home/$name" -Action 'created' -Detail $detail
    }
    $steps
}

# The home's config directory, from the layout owner when it is loaded, so
# FM_CONFIG_OVERRIDE moves config/backend and the doctor's backend check
# together rather than one of them.
function Get-FmInstallConfigDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $entry = @(Get-FmInstallHomeDirectory -FirstmateHome $FirstmateHome |
            Where-Object { $_.Name -eq 'config' })
    if ($entry.Count -eq 1) { return [string]$entry[0].Path }
    Join-Path -Path $FirstmateHome -ChildPath 'config'
}

# --- the default backend --------------------------------------------------------

# THE ONLY SESSION PROVIDER THIS PORT DRIVES IS HERDR. Start-FmWorker's -Backend
# is [ValidateSet('herdr')], and the design report drops the tmux/zellij/orca/
# cmux adapters for Windows outright.
#
# A home with no config/backend resolves to 'tmux' (bin/fm-backend.sh's default,
# preserved by Get-FmBootstrapBackendName), so the captain's very first session
# digest would open with "MISSING: tmux" on a machine where tmux does not exist
# and would not help if it did. Writing the backend this port can actually drive
# is part of producing a WORKING home, not a preference.
#
# An existing config/backend is never overwritten: which backend a home uses is
# the captain's decision, and setup only supplies the answer when none was given.
$script:FmInstallDefaultBackend = 'herdr'

function Set-FmInstallDefaultBackend {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $path = Join-Path -Path (Get-FmInstallConfigDirectory -FirstmateHome $FirstmateHome) -ChildPath 'backend'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $current = ([System.IO.File]::ReadAllText($path) -replace '\s', '')
        return [pscustomobject]@{ Action = 'already'; Detail = "config/backend=$current" }
    }
    if (-not $PSCmdlet.ShouldProcess($path, "write the default backend '$script:FmInstallDefaultBackend'")) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }
    # LF-only and no BOM: config/backend is read by a Linux firstmate sharing
    # this home, so Write-FmSessionTextFile owns the write.
    Write-FmSessionTextFile -Path $path -Content "$script:FmInstallDefaultBackend`n"
    [pscustomobject]@{ Action = 'created'; Detail = "config/backend=$script:FmInstallDefaultBackend" }
}

function Get-FmInstallBackendCheck {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $configDir = Get-FmInstallConfigDirectory -FirstmateHome $FirstmateHome
    $backend = Get-FmBootstrapBackendName -ConfigDir $configDir
    if ($backend -eq $script:FmInstallDefaultBackend) {
        return @(New-FmInstallCheck -Name 'backend' -Status 'ok' -Detail $backend)
    }
    # Not a refusal: the captain may be sharing this home with a Linux firstmate
    # that runs another backend. It is a warning because nothing in THIS port
    # can dispatch onto it.
    return @(New-FmInstallCheck -Name 'backend' -Status 'warn' `
            -Detail "resolves to '$backend'; this port drives '$script:FmInstallDefaultBackend' only, so it cannot dispatch a worker here" `
            -Fix ("set it with: Set-Content -Path '" + (Join-Path $configDir 'backend') + "' -Value $script:FmInstallDefaultBackend"))
}

# --- the managed profile block --------------------------------------------------

function Get-FmInstallProfilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # CurrentUserAllHosts: the console host, the ISE-equivalents, and an editor's
    # integrated terminal all load it, which is what "from any session" means.
    $PROFILE.CurrentUserAllHosts
}

# The literal text of the managed block. A pure function of the three paths, so
# two runs with the same inputs produce identical bytes and the second run can
# report 'already' by comparing text rather than by guessing.
function Get-FmInstallProfileBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$FirstmateHome
    )

    $quote = { param([string]$value) "'" + ($value -replace "'", "''") + "'" }
    $moduleDir = Join-Path $RepoRoot 'module'
    $binDir = Join-Path $RepoRoot 'bin'

    @(
        $script:FmInstallProfileBeginMarker
        '# Managed by Install-FmHome (bin/fm-setup.ps1). Re-run setup to update it;'
        '# everything outside these two markers is left alone.'
        "`$env:FM_HOME = $(& $quote $FirstmateHome)"
        "`$fmwinModuleDir = $(& $quote $moduleDir)"
        "`$fmwinBinDir = $(& $quote $binDir)"
        "`$fmwinSep = [System.IO.Path]::PathSeparator"
        'if (($env:PSModulePath -split $fmwinSep) -notcontains $fmwinModuleDir) {'
        '    $env:PSModulePath = $fmwinModuleDir + $fmwinSep + $env:PSModulePath'
        '}'
        'if (($env:PATH -split $fmwinSep) -notcontains $fmwinBinDir) {'
        '    $env:PATH = $fmwinBinDir + $fmwinSep + $env:PATH'
        '}'
        'Remove-Variable -Name fmwinModuleDir, fmwinBinDir, fmwinSep -ErrorAction SilentlyContinue'
        $script:FmInstallProfileEndMarker
    ) -join "`n"
}

# Splice the managed block into a profile, replacing any previous one.
#
# The surrounding text is written back BYTE-FOR-BYTE, including its line
# endings: this is the captain's own file, not a firstmate contract file, so
# normalizing it would be an uninvited edit. Only the block itself is authored
# here, and it is authored with LF.
function Set-FmInstallProfileBlock {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Block
    )

    $existing = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($Path)
    }

    $pattern = '(?s)' + [regex]::Escape($script:FmInstallProfileBeginMarker) + '.*?' +
        [regex]::Escape($script:FmInstallProfileEndMarker)
    $match = [regex]::Match($existing, $pattern)

    if ($match.Success) {
        if ($match.Value -eq $Block) { return 'already' }
        $updated = $existing.Remove($match.Index, $match.Length).Insert($match.Index, $Block)
        $action = 'updated'
    } else {
        $separator = if ([string]::IsNullOrEmpty($existing)) { '' } elseif ($existing.EndsWith("`n")) { '' } else { "`n" }
        $updated = $existing + $separator + $Block + "`n"
        $action = if ([string]::IsNullOrEmpty($existing)) { 'created' } else { 'updated' }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'write the managed firstmate profile block')) { return 'skipped' }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
    $action
}

function Test-FmInstallProfileBlockCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Block
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?s)' + [regex]::Escape($script:FmInstallProfileBeginMarker) + '.*?' +
        [regex]::Escape($script:FmInstallProfileEndMarker)
    $match = [regex]::Match($text, $pattern)
    return ($match.Success -and $match.Value -eq $Block)
}

# --- Claude hook registration ---------------------------------------------------

function Get-FmInstallHookSettingsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path -Path $RepoRoot -ChildPath '.claude' -AdditionalChildPath 'settings.json'
}

# Merge the port's hook block into a project settings.json.
#
# SCOPE IS DELIBERATELY NARROW. The three events in $FmInstallOwnedHookEvents are
# replaced with what Get-FmClaudeHookSettings emits, because this port owns their
# wiring and a stale half-registration is worse than none. Every other event and
# every other top-level key in the file is carried through untouched, so a
# project that also registers UserPromptSubmit keeps it.
function Set-FmInstallHookRegistration {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $owner = Resolve-FmSessionCommand -Name 'Get-FmClaudeHookSettingsObject', 'Get-FmClaudeHookSettings'
    if (-not $owner) {
        # The hook area owns the settings shape. Without it this step did NOT
        # run - it is never reported as registered.
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'the Claude hook area is not loaded (Get-FmClaudeHookSettingsObject is absent)' }
    }
    $wanted = if ($owner.Name -eq 'Get-FmClaudeHookSettings') { & $owner -AsObject } else { & $owner }
    if ($null -eq $wanted -or -not $wanted.Contains('hooks')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'the Claude hook area returned no hooks block' }
    }

    $document = [ordered]@{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($Path)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try {
                $parsed = $text | ConvertFrom-Json -AsHashtable
            } catch {
                throw "error: '$Path' is not valid JSON; refusing to overwrite a settings file firstmate cannot read"
            }
            if ($parsed -isnot [System.Collections.IDictionary]) {
                throw "error: '$Path' does not contain a JSON object; refusing to overwrite it"
            }
            foreach ($key in $parsed.Keys) { $document[$key] = $parsed[$key] }
        }
    }

    $hooks = [ordered]@{}
    if ($document.Contains('hooks') -and $document['hooks'] -is [System.Collections.IDictionary]) {
        foreach ($hookEvent in $document['hooks'].Keys) {
            if ($script:FmInstallOwnedHookEvents -notcontains $hookEvent) { $hooks[$hookEvent] = $document['hooks'][$hookEvent] }
        }
    }
    foreach ($hookEvent in $wanted['hooks'].Keys) { $hooks[$hookEvent] = $wanted['hooks'][$hookEvent] }
    $document['hooks'] = $hooks

    # LF here as well as in the write: ConvertTo-Json emits the platform newline,
    # and the comparison that decides 'already' has to be against the bytes
    # Write-FmSessionTextFile will actually put on disk.
    $json = ((($document | ConvertTo-Json -Depth 12) -replace "`r`n", "`n") + "`n")
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n") -eq $json) {
        return [pscustomobject]@{ Action = 'already'; Detail = $Path }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'register the firstmate Claude hooks')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $action = if (Test-Path -LiteralPath $Path -PathType Leaf) { 'updated' } else { 'created' }
    Write-FmSessionTextFile -Path $Path -Content $json
    [pscustomobject]@{ Action = $action; Detail = $Path }
}

# Is every event this port owns present in the settings file, pointing at this
# port's hook entry point? Deliberately a shape check, not a byte comparison: a
# captain who raised a timeout has still registered the hooks.
function Test-FmInstallHookRegistered {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $document = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    } catch {
        return $false
    }
    if ($document -isnot [System.Collections.IDictionary]) { return $false }
    if (-not $document.Contains('hooks') -or $document['hooks'] -isnot [System.Collections.IDictionary]) { return $false }

    foreach ($hookEvent in $script:FmInstallOwnedHookEvents) {
        if (-not $document['hooks'].Contains($hookEvent)) { return $false }
        $rendered = $document['hooks'][$hookEvent] | ConvertTo-Json -Depth 12 -Compress
        if ($rendered -notmatch 'fm-claude-hook\.ps1') { return $false }
    }
    $true
}

# --- doctor checks ----------------------------------------------------------------

function Get-FmInstallToolFix {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Tool)

    # Install commands have ONE owner: the bootstrap area, which already keeps a
    # platform-aware table whose line shape the diagnostics skill matches on.
    $manual = Get-FmBootstrapManualInstallUrl -Tool $Tool
    if ($manual) { return "install it manually: $manual" }
    $cmd = Get-FmBootstrapInstallCommand -Tool $Tool
    if ($cmd) { return $cmd }
    ''
}

# One run of `<command> --version`, reported as the three facts that decide what
# is said about it: was it on PATH, did Windows let it START, and what did it
# print. Running it twice to learn two of them would double every detection pass,
# so both callers come through here and the version-only caller drops the rest.
function Get-FmInstallCommandProbe {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @('--version')
    )

    $res = Invoke-FmSessionCommandLine -Command $Command -Arguments $Arguments
    $version = ''
    if ($res.Launched -and $res.ExitCode -eq 0) {
        $line = @($res.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($line.Count -gt 0) { $version = ([string]$line[0]).Trim() }
    }
    [pscustomobject]@{
        Found    = [bool]$res.Found
        Launched = [bool]$res.Launched
        Version  = $version
    }
}

function Get-FmInstallCommandVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @('--version')
    )

    (Get-FmInstallCommandProbe -Command $Command -Arguments $Arguments).Version
}

function Get-FmInstallPrerequisiteCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $checks = @()

    # PowerShell 7 is the platform, not a dependency: nothing else in this port
    # runs without it, so it is the one check that cannot be warned past.
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 7) {
        $checks += New-FmInstallCheck -Name 'PowerShell 7' -Status 'ok' -Detail $psVersion.ToString() -Required
    } else {
        $checks += New-FmInstallCheck -Name 'PowerShell 7' -Status 'missing' -Required `
            -Detail "this session is PowerShell $psVersion" `
            -Fix 'winget install Microsoft.PowerShell, then re-run this from pwsh (not Windows PowerShell)'
    }

    if (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue) {
        $checks += New-FmInstallCheck -Name 'git' -Status 'ok' -Detail (Get-FmInstallCommandVersion -Command 'git') -Required
    } else {
        $checks += New-FmInstallCheck -Name 'git' -Status 'missing' -Required `
            -Detail 'not on PATH' -Fix (Get-FmInstallToolFix -Tool 'git')
    }

    $pester = @(Get-Module -ListAvailable -Name 'Pester' | Sort-Object Version -Descending | Select-Object -First 1)
    if ($pester.Count -gt 0 -and $pester[0].Version.Major -ge 5) {
        $checks += New-FmInstallCheck -Name 'Pester 5+' -Status 'ok' -Detail $pester[0].Version.ToString()
    } elseif ($pester.Count -gt 0) {
        $checks += New-FmInstallCheck -Name 'Pester 5+' -Status 'warn' -Detail "found $($pester[0].Version)" `
            -Fix 'Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force'
    } else {
        $checks += New-FmInstallCheck -Name 'Pester 5+' -Status 'warn' -Detail 'not installed (needed to run the suite, not to run firstmate)' `
            -Fix 'Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force'
    }

    # herdr is the only session provider this port drives. Without it a worker
    # cannot be dispatched, but a home is still installable and inspectable, so
    # it is a warn and not a hard prerequisite.
    if (Get-Command -Name 'herdr' -CommandType Application -ErrorAction SilentlyContinue) {
        $checks += New-FmInstallCheck -Name 'herdr' -Status 'ok' -Detail (Get-FmInstallCommandVersion -Command 'herdr')
    } else {
        $checks += New-FmInstallCheck -Name 'herdr' -Status 'warn' `
            -Detail 'not on PATH - no worker can be dispatched without the session provider' `
            -Fix (Get-FmInstallToolFix -Tool 'herdr')
    }

    if (-not (Get-Command -Name 'treehouse' -CommandType Application -ErrorAction SilentlyContinue)) {
        $checks += New-FmInstallCheck -Name 'treehouse' -Status 'warn' `
            -Detail 'not on PATH - no worker can be given an isolated worktree' `
            -Fix (Get-FmInstallToolFix -Tool 'treehouse')
    } elseif (-not (Test-FmBootstrapTreehouseSupportsLease)) {
        $checks += New-FmInstallCheck -Name 'treehouse' -Status 'warn' `
            -Detail "installed build has no 'get --lease'; this port acquires worktrees with a durable lease" `
            -Fix (Get-FmInstallToolFix -Tool 'treehouse')
    } else {
        $checks += New-FmInstallCheck -Name 'treehouse' -Status 'ok' `
            -Detail ((Get-FmInstallCommandVersion -Command 'treehouse') + ' (get --lease supported)').Trim()
    }

    if (Get-Command -Name 'claude' -CommandType Application -ErrorAction SilentlyContinue) {
        $checks += New-FmInstallCheck -Name 'Claude CLI' -Status 'ok' -Detail (Get-FmInstallCommandVersion -Command 'claude')
    } else {
        # The route comes from the owner, not from a string here. This line used
        # to name npm, which is a genuine Anthropic package but not what the rest
        # of the port installs, and a second copy of a route is how the machine
        # install came to disagree with the digest about two other tools.
        $checks += New-FmInstallCheck -Name 'Claude CLI' -Status 'warn' `
            -Detail 'not on PATH - the hooks are registered but nothing will run them' `
            -Fix (Get-FmInstallToolFix -Tool 'claude')
    }

    $checks
}

# WHAT THIS CHECK IS ABOUT, AND WHY IT IS NOT '$env:FM_HOME IS SET'.
#
# It used to be. That reported [missing] in every shell that had not loaded the
# profile - which is every herdr pane, every Claude hook, every dispatched
# worker - while the same install reported healthy in the captain's own window.
# Worse, it reported nothing at all about the real damage: with FM_HOME unset
# Get-FmHome falls through to the code root, so those shells silently used the
# CHECKOUT as the home and exited 0.
#
# The thing that actually has to be true is that the home resolves WITHOUT the
# environment, which is what <checkout>/.fm-home is for. So that is what this
# check tests. An environment variable on top of it is an override and is
# reported as one.
function Get-FmInstallHomeCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [string]$HomePointerPath = '',
        [string]$RepoRoot = ''
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not $HomePointerPath) { $HomePointerPath = Get-FmHomePointerPath -RepoRoot $RepoRoot }
    $pointer = Read-FmHomePointer -Path $HomePointerPath

    $checks = @()
    if (-not $pointer) {
        # Name the home a bare shell would ACTUALLY have used, because that is
        # the failure - not the absence of a file.
        $bare = Get-FmHome
        $checks += New-FmInstallCheck -Name 'FM_HOME' -Status 'missing' -Required `
            -Detail ("no $HomePointerPath, so a shell that did not load the profile resolves the home to '$bare'") `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'"
    } elseif (Test-FmPathEqual -Left $pointer -Right $FirstmateHome) {
        $checks += New-FmInstallCheck -Name 'FM_HOME' -Status 'ok' -Required `
            -Detail "$FirstmateHome (persisted in $HomePointerPath; resolves with no profile and no environment)"
    } else {
        # A legitimate override, not a fault: a secondmate home, a test home, or
        # the captain saying otherwise for one session. Say which is winning.
        $checks += New-FmInstallCheck -Name 'FM_HOME' -Status 'ok' -Required `
            -Detail "$FirstmateHome (overriding the persisted '$pointer' in $HomePointerPath)"
    }

    if (-not (Test-Path -LiteralPath $FirstmateHome -PathType Container)) {
        $checks += New-FmInstallCheck -Name 'home layout' -Status 'missing' -Required `
            -Detail "'$FirstmateHome' does not exist" `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'"
        return $checks
    }

    $directories = @(Get-FmInstallHomeDirectory -FirstmateHome $FirstmateHome)
    $absent = @()
    foreach ($entry in $directories) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Container)) { $absent += $entry.Name }
    }
    if ($absent.Count -gt 0) {
        $checks += New-FmInstallCheck -Name 'home layout' -Status 'missing' -Required `
            -Detail ("'$FirstmateHome' is missing " + ($absent -join ', ')) `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'"
    } else {
        $checks += New-FmInstallCheck -Name 'home layout' -Status 'ok' -Required `
            -Detail ($FirstmateHome + ' (' + (($directories | ForEach-Object { $_.Name }) -join ', ') + ')')
    }
    $checks += Get-FmInstallHomeLocationCheck -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot
    $checks += Get-FmInstallBackendCheck -FirstmateHome $FirstmateHome
    $checks
}

# WHERE DO I START CLAUDE? The one question the split home made unanswerable.
#
# ok      the home IS the checkout, so `cd <here>; claude` works exactly as the
#         Linux docs say - one directory, instructions, hooks and state together
# warn    they are separate, but the home carries the redirect, so a session
#         started in the wrong one stops and names the right one
# missing they are separate and NOTHING says so - a session started in the home
#         comes up with no instructions, no digest and no supervision, silently
function Get-FmInstallHomeLocationCheck {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $checkoutClaude = Join-Path $RepoRoot 'CLAUDE.md'
    $memoryBroken = @()
    if (-not (Test-Path -LiteralPath $checkoutClaude -PathType Leaf)) {
        $memoryBroken += "$checkoutClaude is missing"
    } elseif (Test-FmAgentsLinkPlaceholder -ClaudePath $checkoutClaude) {
        # MEASURED on the laptop: a 9-byte file containing 'AGENTS.md'. A session
        # started there reads one filename and gets no instructions.
        $memoryBroken += "$checkoutClaude is the text git leaves for a symlink, not the instructions"
    }

    if (Test-FmInstallHomeIsCheckout -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot) {
        if ($memoryBroken.Count -gt 0) {
            return @(New-FmInstallCheck -Name 'start Claude in' -Status 'missing' -Required `
                    -Detail ("$RepoRoot - the home IS the checkout, but " + ($memoryBroken -join '; ') +
                        ', so a session started there gets no instructions') `
                    -Fix 'bin/fm-setup.ps1')
        }
        return @(New-FmInstallCheck -Name 'start Claude in' -Status 'ok' -Required `
                -Detail "$RepoRoot - the home IS the checkout, as on Linux")
    }

    if (-not (Test-Path -LiteralPath $FirstmateHome -PathType Container)) {
        # The home layout check already reports the absent home; do not report a
        # redirect as missing from a directory that does not exist.
        return @(New-FmInstallCheck -Name 'start Claude in' -Status 'warn' `
                -Detail "$RepoRoot - the home '$FirstmateHome' is separate from the checkout and does not exist yet" `
                -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'")
    }

    if (Test-FmInstallHomeRedirectCurrent -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot) {
        return @(New-FmInstallCheck -Name 'start Claude in' -Status 'warn' `
                -Detail ("$RepoRoot - NOT '$FirstmateHome', which holds only this instance's state; " +
                    'that directory says so in its own AGENTS.md and CLAUDE.md') `
                -Fix "cd $RepoRoot")
    }

    return @(New-FmInstallCheck -Name 'start Claude in' -Status 'missing' -Required `
            -Detail ("$RepoRoot - and nothing stops a session started in '$FirstmateHome', which has no " +
                'AGENTS.md, no CLAUDE.md and no .claude/, so an agent there gets no instructions and no hooks') `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'")
}

function Get-FmInstallWiringCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$HookSettingsPath
    )

    $checks = @()

    # The proof that `Import-Module Firstmate` resolves is that PowerShell's own
    # discovery finds it on PSModulePath - not that a manifest file exists
    # somewhere. Get-Module -ListAvailable is that discovery.
    # MISSING vs WARN IS THE WHOLE POINT OF THIS GROUP. A missing manifest is
    # broken: nothing can run. Everything else here is about the CAPTAIN'S
    # INTERACTIVE SHELL being able to type `Import-Module Firstmate` and
    # `fm-doctor.ps1` bare - which the profile block provides and nothing else
    # does. An entry point run by its own path works either way, because
    # bin/fm-module-load.ps1 wires its own process. So: convenience, therefore
    # warn. Reporting these as [missing] is what made one working install
    # report "unhealthy: 3 missing" the moment it was run without a profile.
    $manifest = Join-Path -Path $RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate', 'Firstmate.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        $checks += New-FmInstallCheck -Name 'Firstmate module' -Status 'missing' -Required `
            -Detail "no manifest at '$manifest'" -Fix 'this checkout is incomplete; re-clone it'
    } elseif (@(Get-Module -ListAvailable -Name 'Firstmate' -ErrorAction SilentlyContinue).Count -gt 0) {
        $checks += New-FmInstallCheck -Name 'Firstmate module' -Status 'ok' -Required `
            -Detail 'Import-Module Firstmate resolves on PSModulePath'
    } else {
        $checks += New-FmInstallCheck -Name 'Firstmate module' -Status 'warn' `
            -Detail ("bare 'Import-Module Firstmate' does not resolve in this session; " +
                'the entry points import the manifest at ' + $manifest + ' themselves') `
            -Fix 'open a new PowerShell session, which loads the profile block bin/fm-setup.ps1 writes'
    }

    $binDir = Join-Path $RepoRoot 'bin'
    $onPath = @($env:PATH -split [System.IO.Path]::PathSeparator |
            Where-Object { $_ } | Where-Object { Test-FmPathEqual -Left $_ -Right $binDir })
    if ($onPath.Count -gt 0) {
        $checks += New-FmInstallCheck -Name 'fm-* entry points' -Status 'ok' -Required -Detail "$binDir is on PATH"
    } else {
        $checks += New-FmInstallCheck -Name 'fm-* entry points' -Status 'warn' `
            -Detail ("$binDir is not on PATH in this session, so the bare command name does not work; " +
                'running one by its full path does') `
            -Fix 'open a new PowerShell session, which loads the profile block bin/fm-setup.ps1 writes'
    }

    $block = Get-FmInstallProfileBlock -RepoRoot $RepoRoot -FirstmateHome $FirstmateHome
    if (Test-FmInstallProfileBlockCurrent -Path $ProfilePath -Block $block) {
        $checks += New-FmInstallCheck -Name 'profile wiring' -Status 'ok' -Detail $ProfilePath
    } elseif (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
        $checks += New-FmInstallCheck -Name 'profile wiring' -Status 'warn' `
            -Detail "$ProfilePath has no current firstmate block (the checkout or the home may have moved)" `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'"
    } else {
        $checks += New-FmInstallCheck -Name 'profile wiring' -Status 'warn' `
            -Detail "no profile at $ProfilePath, so a new session gets no firstmate wiring of its own" `
            -Fix "bin/fm-setup.ps1 -FirstmateHome '$FirstmateHome'"
    }

    if (Test-FmInstallHookRegistered -Path $HookSettingsPath) {
        $checks += New-FmInstallCheck -Name 'Claude hooks' -Status 'ok' `
            -Detail ("SessionStart, PreToolUse, Stop registered in " + $HookSettingsPath)
    } else {
        $checks += New-FmInstallCheck -Name 'Claude hooks' -Status 'missing' `
            -Detail "not registered in $HookSettingsPath" `
            -Fix 'bin/fm-setup.ps1'
    }

    $checks
}
