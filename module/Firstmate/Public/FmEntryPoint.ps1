#requires -Version 7.0
Set-StrictMode -Version Latest

<#
    FmEntryPoint - what a bin/fm-*.ps1 needs to be true before it can do anything,
    in a shell that never loaded a PowerShell profile.

    WHY THIS AREA EXISTS. The install area wires a managed block into
    $PROFILE.CurrentUserAllHosts: it prepends module/ to PSModulePath, bin/ to
    PATH, and exports FM_HOME. That block is loaded by an interactive session and
    by nothing else. herdr panes, Claude hooks, scheduled tasks, IDE terminals,
    a window opened before setup ran - and, decisively, the worker sessions
    firstmate dispatches itself - all start with `-NoProfile` or with a profile
    that has not been reloaded. On the captain's laptop that produced two
    failures from ONE install:

      pwsh -ExecutionPolicy Bypass -Command "fm-doctor.ps1"      -> healthy, exit 0
      pwsh -NoProfile -ExecutionPolicy Bypass -File fm-doctor.ps1 -> 3 missing, exit 1

    and, worse because it is silent, `bin/fm-home.ps1` in the same bare shell
    printed the CHECKOUT as the home and exited 0. Get-FmHome's documented tail
    is the code root (the bash contract, where the checkout IS the home), so with
    FM_HOME unset every state read and write went to the wrong directory while
    every command reported success.

    THE FIX IS A FILE, NOT AN ENVIRONMENT VARIABLE. Setup persists the chosen
    home in '.fm-home' beside the checkout. A file next to the script is readable
    from the script's own $PSScriptRoot with nothing configured, which is the
    only property that survives a bare shell. The environment variable still
    wins, so an override - a secondmate home, a test home - keeps working
    exactly as it did.

    WHERE THE PIECES LIVE. This file owns the pointer and the precedence.
    bin/fm-module-load.ps1 owns making the module importable at all (PSModulePath
    cannot be fixed from inside a module that has not been imported yet) and is
    the ONE place that publishes the resolved home into the process. Every entry
    point dot-sources that prelude; none of them repeats any of this.
#>

# The pointer's name. A leading dot keeps it out of the way in a directory
# listing; it is not a hidden-attribute file on Windows, which is deliberate -
# the captain must be able to see and delete it.
$script:FmHomePointerFileName = '.fm-home'

function Get-FmHomePointerPath {
    <#
        .SYNOPSIS
        Path of the file setup persists the chosen home in.

        .DESCRIPTION
        Beside the checkout, so two checkouts can point at two different homes
        and each stays self-consistent. -RepoRoot defaults to Get-FmRoot, the
        foundation's one owner of "where the tracked code lives".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RepoRoot = '')

    if (-not $RepoRoot) { $RepoRoot = Get-FmRoot }
    Join-Path $RepoRoot $script:FmHomePointerFileName
}

function Read-FmHomePointer {
    <#
        .SYNOPSIS
        The home setup persisted beside a checkout, or $null when there is none.

        .DESCRIPTION
        NEVER THROWS. This runs before anything else in an entry point, so an
        unreadable, empty or half-written pointer has to degrade to "no pointer"
        rather than take the command down with it - the caller then falls back
        to the documented default and the doctor reports the pointer as missing.
        A relative path is resolved so the answer is always absolute.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path = '')

    if (-not $Path) { $Path = Get-FmHomePointerPath }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $text = [System.IO.File]::ReadAllText($Path)
    } catch {
        Write-Debug "home pointer '$Path' is unreadable: $($_.Exception.Message)"
        return $null
    }

    # First non-blank line, so a pointer a human annotated with a comment line
    # still parses and a trailing newline is not mistaken for content.
    $value = @($text -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Select-Object -First 1)
    if ($value.Count -eq 0) { return $null }

    try { return Resolve-FmFullPath -Path $value[0] } catch {
        Write-Debug "home pointer '$Path' holds an unusable path: $($_.Exception.Message)"
        return $null
    }
}

function Write-FmHomePointer {
    <#
        .SYNOPSIS
        Persist the chosen home beside a checkout. Idempotent.

        .DESCRIPTION
        Returns 'created', 'already' or 'updated' so setup reports the same
        converge-not-append shape as every other install step. The bytes are
        UTF-8 without a BOM and LF-only through Write-FmTextFileLf: a Linux
        firstmate sharing this checkout must be able to read it.

        -Path is overridable for the same reason Install-FmHome's -ProfilePath
        is: the suite runs setup against the REAL checkout, because the profile
        block it writes has to name the real module/ and bin/, and a test must
        not leave a pointer in the developer's working tree.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [string]$Path = ''
    )

    if (-not $Path) { $Path = Get-FmHomePointerPath }
    $content = (Resolve-FmFullPath -Path $HomePath) + "`n"

    $action = 'created'
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([System.IO.File]::ReadAllText($Path) -eq $content) { return 'already' }
        $action = 'updated'
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'persist the firstmate home')) { return 'skipped' }
    Write-FmTextFileLf -Path $Path -Text $content
    $action
}

function Resolve-FmEntryPointHome {
    <#
        .SYNOPSIS
        The home an entry point should use, with no profile and no environment.

        .DESCRIPTION
        Precedence, highest first:

          1. -HomePath, the caller's explicit choice
          2. the environment - FM_HOME, then FM_ROOT_OVERRIDE, delegated whole to
             Get-FmHome so the bash contract keeps exactly one owner
          3. the value setup persisted in <checkout>/.fm-home
          4. the documented default - THE CHECKOUT, which is Get-FmHome's own
             tail and the layout the Linux firstmate has: the repo root IS the
             home there, with config/ data/ projects/ state/ gitignored beside
             AGENTS.md and .claude/. -RepoRoot names which checkout when the
             caller has one in hand; otherwise Get-FmHome answers.

        THIS IS ALSO THE INSTALLER'S ANSWER. It used to keep a second copy of
        this question that ended in <userprofile>/firstmate, so a fresh install
        put the home somewhere the module's own resolution never pointed - and
        `cd <home>; claude`, which is exactly what the Linux docs tell a captain
        to do, landed in a directory with no AGENTS.md and no hooks.

        THE ENVIRONMENT DELIBERATELY OUTRANKS THE PERSISTED VALUE. A secondmate
        home, a test home and a one-off `$env:FM_HOME = ... ; fm-...` are all the
        same act, and an installed pointer must never quietly win over the
        captain saying otherwise in this session.

        Steps 2 and 4 are the same call because Get-FmHome already implements
        both halves; the pointer is spliced between them and nothing else about
        the foundation's resolution changes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$HomePath = '',
        [string]$RepoRoot = '',
        [string]$PointerPath = ''
    )

    if ($HomePath) { return Resolve-FmFullPath -Path $HomePath }
    if (Test-FmEntryPointHomeInEnvironment) { return Get-FmHome }

    if (-not $PointerPath) { $PointerPath = Get-FmHomePointerPath -RepoRoot $RepoRoot }
    $persisted = Read-FmHomePointer -Path $PointerPath
    if ($persisted) { return $persisted }

    # Reaching here means the environment said nothing, so Get-FmHome would
    # return Get-FmRoot - the checkout this MODULE was loaded from. A caller
    # that named a checkout means that one.
    if ($RepoRoot) { return Resolve-FmFullPath -Path $RepoRoot }
    return Get-FmHome
}

function Test-FmEntryPointHomeInEnvironment {
    <#
        .SYNOPSIS
        True when this process's environment already names a home.

        .DESCRIPTION
        Both of Get-FmHome's environment steps, asked as one question, so the
        resolver and the publisher below cannot drift on which variables count.
        An empty variable is unset, matching bash's ${VAR:-default}.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool]((Get-FmEnvValue -Name 'FM_HOME') -or (Get-FmEnvValue -Name 'FM_ROOT_OVERRIDE'))
}

function Initialize-FmEntryPointHome {
    <#
        .SYNOPSIS
        Publish the persisted home into $env:FM_HOME for this process, and
        return the home an entry point should use.

        .DESCRIPTION
        Called once by bin/fm-module-load.ps1, so nine functions across seven
        areas that read $env:FM_HOME directly - and every child process an entry
        point spawns, including the herdr pane a dispatched worker runs in - see
        the right home without any of them learning a new rule.

        IT PUBLISHES THE POINTER AND NOTHING ELSE. When the environment already
        names a home there is nothing to add. When there is no pointer either,
        the answer is Get-FmHome's documented fallback, and writing THAT into the
        environment would be a guess that then outranks a pointer written later
        and would be exported to every child. The first version of this did
        exactly that: a setup run followed by fm-home.ps1 in the same session
        printed the checkout as the home, because setup's own prelude had pinned
        the fallback before setup wrote the pointer. So the fallback stays a
        fallback, recomputed by Get-FmHome on demand, and fm-doctor reports the
        absent pointer by name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$RepoRoot = '',
        [string]$PointerPath = ''
    )

    if (-not $PointerPath) { $PointerPath = Get-FmHomePointerPath -RepoRoot $RepoRoot }
    $resolved = Resolve-FmEntryPointHome -RepoRoot $RepoRoot -PointerPath $PointerPath

    if (Test-FmEntryPointHomeInEnvironment) { return $resolved }
    if (-not (Read-FmHomePointer -Path $PointerPath)) { return $resolved }
    if ($PSCmdlet.ShouldProcess('$env:FM_HOME', "publish the persisted home '$resolved'")) {
        $env:FM_HOME = $resolved
    }
    return $resolved
}
