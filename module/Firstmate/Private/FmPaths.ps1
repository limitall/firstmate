<#
    FmPaths - operational home resolution and the data/state/config/projects layout.

    ONE owner of "where does this instance's private state live". Ported from the
    three lines every bash entry point repeats (bin/fm-lock.sh, bin/fm-wake-lib.sh):

        FM_ROOT="${FM_ROOT_OVERRIDE:-<code root>}"
        FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
        STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

    The precedence is preserved exactly, including FM_STATE_OVERRIDE pointing the
    state directory somewhere other than $FM_HOME/state while data/, config/ and
    projects/ still follow the home (AGENTS.md section 2).

    FM_HOME selects an instance's private data/, state/, config/ and projects/,
    while scripts keep coming from their tracked code root - so Get-FmRoot and
    Get-FmHome are deliberately separate answers.

    The home parameter is spelled -HomePath, never -Home: a parameter named Home
    would shadow the engine's $HOME inside every one of these functions.
#>

Set-StrictMode -Version Latest

# An environment variable set to the empty string counts as unset, matching the
# ${VAR:-default} form the bash scripts use (colon-minus treats empty as unset).
function Get-FmEnvValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Get-FmModuleRoot {
    <#
        .SYNOPSIS
        Directory holding Firstmate.psd1/.psm1.
    #>
    $variable = Get-Variable -Name 'FmModuleRoot' -Scope Script -ErrorAction SilentlyContinue
    if ($variable -and $variable.Value) { return [string]$variable.Value }
    # Fallback for a Private file dot-sourced directly (tests, diagnostics):
    # this file is <module>/Private/FmPaths.ps1.
    return (Split-Path -Parent $PSScriptRoot)
}

function Resolve-FmFullPath {
    <#
        .SYNOPSIS
        Absolute, normalized path for a path that need not exist yet.

        .DESCRIPTION
        Resolve-Path fails on a missing path and Convert-Path needs a provider
        path, so neither works for "the state file we are about to create".
        Relative input resolves against the caller's real filesystem location,
        never against a PowerShell drive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw [System.ArgumentException]::new('Path must not be empty', 'Path')
    }
    $full = [System.IO.Path]::GetFullPath($Path, $PWD.ProviderPath)
    # Trim a trailing separator so "<home>/state/" and "<home>/state" compare
    # equal; a filesystem root ("C:\", "/") keeps its separator.
    if ([System.IO.Path]::GetPathRoot($full) -eq $full) { return $full }
    return $full.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
}

function Get-FmRoot {
    <#
        .SYNOPSIS
        Tracked code root - where bin/, module/ and tests/ live.

        .DESCRIPTION
        FM_ROOT_OVERRIDE wins, then the repository containing this module
        (<root>/module/Firstmate). Scripts always come from the code root even
        when FM_HOME points the private state somewhere else entirely.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $override = Get-FmEnvValue -Name 'FM_ROOT_OVERRIDE'
    if ($override) { return Resolve-FmFullPath -Path $override }
    # <root>/module/Firstmate -> <root>
    return Resolve-FmFullPath -Path (Split-Path -Parent (Split-Path -Parent (Get-FmModuleRoot)))
}

function Get-FmHome {
    <#
        .SYNOPSIS
        This instance's operational home (FM_HOME).

        .DESCRIPTION
        Precedence, from bash: FM_HOME, then FM_ROOT_OVERRIDE, then the code
        root. Each secondmate has its own persistent isolated home, which is why
        nothing here caches the answer across calls.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $value = Get-FmEnvValue -Name 'FM_HOME'
    if ($value) { return Resolve-FmFullPath -Path $value }
    $override = Get-FmEnvValue -Name 'FM_ROOT_OVERRIDE'
    if ($override) { return Resolve-FmFullPath -Path $override }
    return Get-FmRoot
}

function Get-FmStateRoot {
    <#
        .SYNOPSIS
        Volatile runtime records directory.

        .DESCRIPTION
        FM_STATE_OVERRIDE wins over <home>/state, exactly as bash does - but only
        when the caller did not name a home. An explicit -HomePath is a request
        for THAT home's state (a secondmate home, a test home), and an ambient
        override must not redirect it somewhere else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)

    if (-not $PSBoundParameters.ContainsKey('HomePath')) {
        $override = Get-FmEnvValue -Name 'FM_STATE_OVERRIDE'
        if ($override) { return Resolve-FmFullPath -Path $override }
        $HomePath = Get-FmHome
    }
    return Resolve-FmFullPath -Path (Join-Path $HomePath 'state')
}

function Get-FmDataRoot {
    <#
        .SYNOPSIS
        Durable private fleet records directory (<home>/data).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)
    if (-not $HomePath) { $HomePath = Get-FmHome }
    return Resolve-FmFullPath -Path (Join-Path $HomePath 'data')
}

function Get-FmConfigRoot {
    <#
        .SYNOPSIS
        Local operating choices directory (<home>/config).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)
    if (-not $HomePath) { $HomePath = Get-FmHome }
    return Resolve-FmFullPath -Path (Join-Path $HomePath 'config')
}

function Get-FmProjectsRoot {
    <#
        .SYNOPSIS
        Cloned repositories directory (<home>/projects).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)
    if (-not $HomePath) { $HomePath = Get-FmHome }
    return Resolve-FmFullPath -Path (Join-Path $HomePath 'projects')
}

function Get-FmHomeLayout {
    <#
        .SYNOPSIS
        The whole resolved layout in one object - what bin/fm-home.ps1 prints.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $explicit = $PSBoundParameters.ContainsKey('HomePath')
    if ($explicit) { $HomePath = Resolve-FmFullPath -Path $HomePath } else { $HomePath = Get-FmHome }
    $stateArgs = @{}
    if ($explicit) { $stateArgs['HomePath'] = $HomePath }

    return [pscustomobject]@{
        PSTypeName = 'Firstmate.HomeLayout'
        Root       = Get-FmRoot
        Home       = $HomePath
        State      = Get-FmStateRoot @stateArgs
        Data       = Get-FmDataRoot -HomePath $HomePath
        Config     = Get-FmConfigRoot -HomePath $HomePath
        Projects   = Get-FmProjectsRoot -HomePath $HomePath
    }
}

function Get-FmPath {
    <#
        .SYNOPSIS
        One accessor for any layout directory, optionally with a child path.

        .EXAMPLE
        Get-FmPath -Kind State -ChildPath '.wake-queue'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Root', 'Home', 'State', 'Data', 'Config', 'Projects')]
        [string]$Kind,

        [string[]]$ChildPath,
        [string]$HomePath
    )

    $homeArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath')) { $homeArgs['HomePath'] = $HomePath }

    $base = switch ($Kind) {
        'Root' { Get-FmRoot }
        'Home' { if ($HomePath) { Resolve-FmFullPath -Path $HomePath } else { Get-FmHome } }
        'State' { Get-FmStateRoot @homeArgs }
        'Data' { Get-FmDataRoot @homeArgs }
        'Config' { Get-FmConfigRoot @homeArgs }
        'Projects' { Get-FmProjectsRoot @homeArgs }
    }
    if (-not $ChildPath -or $ChildPath.Count -eq 0) { return $base }

    $path = $base
    foreach ($segment in $ChildPath) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        if ([System.IO.Path]::IsPathRooted($segment)) {
            throw [System.ArgumentException]::new(
                "ChildPath segment '$segment' is absolute; Get-FmPath composes paths under the home", 'ChildPath')
        }
        $path = Join-Path $path $segment
    }
    return Resolve-FmFullPath -Path $path
}

function Get-FmStatePath {
    <#
        .SYNOPSIS
        Path under state/ (the whole directory when -Name is omitted).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Name, [string]$HomePath)
    $splat = @{ Kind = 'State' }
    if ($Name) { $splat['ChildPath'] = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmPath @splat
}

function Get-FmDataPath {
    <#
        .SYNOPSIS
        Path under data/ (the whole directory when -Name is omitted).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Name, [string]$HomePath)
    $splat = @{ Kind = 'Data' }
    if ($Name) { $splat['ChildPath'] = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmPath @splat
}

function Get-FmBacklogPath {
    <#
        .SYNOPSIS
        This home's backlog file: <home>/data/backlog.md.

        .DESCRIPTION
        The ONE answer to "where is this home's task queue", and the reason it
        is here rather than in the backlog area: the answer has two independent
        readers - the backlog commands that WRITE the queue and the session-start
        digest that READS it - and each used to compute it for itself.

        They disagreed. The digest joined <home>/data/backlog.md, exactly as
        bin/fm-session-start.sh does, while the backlog area probed
        <home>/backlog.md first and fell back to creating it there. In a fresh
        home neither file existed, so `add` created the root one, the probe kept
        finding it, and the digest reported the queue ABSENT while the captain's
        work items sat in a file nothing else read. That does not fail; it
        LOSES, which is why the location is now a single function both callers
        must go through.

        data/backlog.md is the authoritative location: it is what the Linux
        firstmate's tracked .tasks.toml pins, what docs/configuration.md
        documents, what AGENTS.md section 2 lists in the home layout, and what
        every other reader in this port already assumed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)
    $splat = @{ Name = 'backlog.md' }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmDataPath @splat
}

function Get-FmBacklogLegacyPath {
    <#
        .SYNOPSIS
        The pre-fix location a backlog could have been created in: <home>/backlog.md.

        .DESCRIPTION
        Named, not guessed at three call sites. A home that ran `fm-backlog.ps1
        add` before the resolution was single-sourced has its real work items
        here, and Repair-FmBacklogLocation is what reconciles that.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)
    $splat = @{ Kind = 'Home'; ChildPath = 'backlog.md' }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmPath @splat
}

function Get-FmConfigPath {
    <#
        .SYNOPSIS
        Path under config/ (the whole directory when -Name is omitted).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Name, [string]$HomePath)
    $splat = @{ Kind = 'Config' }
    if ($Name) { $splat['ChildPath'] = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmPath @splat
}

function Get-FmProjectPath {
    <#
        .SYNOPSIS
        Path under projects/ (the whole directory when -Name is omitted).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Name, [string]$HomePath)
    $splat = @{ Kind = 'Projects' }
    if ($Name) { $splat['ChildPath'] = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmPath @splat
}

function Test-FmTaskId {
    <#
        .SYNOPSIS
        True for an id safe to use as a state filename component.

        .DESCRIPTION
        The bash charset is [A-Za-z0-9._-] (fm_meta_lock_path,
        fm_recovery_marker_read). "." and ".." are rejected on top of it: they
        pass the charset but are directory traversal, and a trailing dot is
        rejected because Windows silently strips it, which would alias two
        distinct ids onto one file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$TaskId)

    if ([string]::IsNullOrEmpty($TaskId)) { return $false }
    if ($TaskId -eq '.' -or $TaskId -eq '..') { return $false }
    if ($TaskId.EndsWith('.')) { return $false }
    return $TaskId -cmatch '^[A-Za-z0-9._-]+$'
}

function Get-FmTaskStatePath {
    <#
        .SYNOPSIS
        Path of one task's state record, e.g. state/<id>.meta.

        .DESCRIPTION
        -Suffix is the bare extension ('meta', 'status', 'turn-ended', ...), so
        callers never hand-build "<id>.<suffix>" and never skip id validation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Suffix,
        [string]$HomePath
    )

    if (-not (Test-FmTaskId -TaskId $TaskId)) {
        throw [System.ArgumentException]::new("invalid task id: '$TaskId'", 'TaskId')
    }
    $clean = $Suffix.TrimStart('.')
    if ($clean -notmatch '^[A-Za-z0-9._-]+$') {
        throw [System.ArgumentException]::new("invalid state-file suffix: '$Suffix'", 'Suffix')
    }
    $splat = @{ Name = "$TaskId.$clean" }
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    return Get-FmStatePath @splat
}

function Initialize-FmHome {
    <#
        .SYNOPSIS
        Create the home's data/, state/, config/ and projects/ directories.

        .DESCRIPTION
        Idempotent, and it never touches contents. Returns the resolved layout so
        a caller can create and use a home in one step.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $splat = @{}
    if ($PSBoundParameters.ContainsKey('HomePath')) { $splat['HomePath'] = $HomePath }
    $layout = Get-FmHomeLayout @splat

    foreach ($dir in @($layout.Home, $layout.State, $layout.Data, $layout.Config, $layout.Projects)) {
        if (Test-Path -LiteralPath $dir -PathType Container) { continue }
        if ($PSCmdlet.ShouldProcess($dir, 'Create directory')) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
    }
    return $layout
}
