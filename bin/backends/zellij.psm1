# bin/backends/zellij.psm1 - the zellij session-provider adapter (EXPERIMENTAL).
#
# Twin: bin/backends/zellij.sh
#
# Zellij is a session provider ONLY: treehouse stays the worktree provider,
# exactly as for tmux and herdr. ONE zellij session (default "firstmate",
# overridable through FM_ZELLIJ_SESSION for test isolation), ONE tab per task.
# Target string shape: "<zellij-session>:<pane-id>", the pane id a bare
# non-negative integer with no embedded colon, so splitting on the FIRST colon
# is trivially correct.
#
# Bash -> PowerShell map, with each function's RETURN CONVENTION:
#
#   bin/backends/zellij.sh                    this file                             returns
#   ----------------------------------------  ------------------------------------  ----------------------
#   fm_backend_zellij_session                 Get-FmBackendZellijSession            session name
#   fm_backend_zellij_home_label              Get-FmBackendZellijHomeLabel          home tag
#   fm_backend_zellij_scoped_title            Get-FmBackendZellijScopedTitle        tagged title
#   fm_backend_zellij_tool_check              Test-FmBackendZellijTool              [bool] + stderr
#   fm_backend_zellij_version_check           Test-FmBackendZellijVersion           [bool] + stderr
#   fm_backend_zellij_cli                     Invoke-FmBackendZellijCli             Invoke-FmTool hashtable
#   fm_backend_zellij_session_exists          Test-FmBackendZellijSessionExists     [bool]
#   fm_backend_zellij_server_ensure           Initialize-FmBackendZellijServer      [bool]
#   fm_backend_zellij_container_ensure        Initialize-FmBackendZellijContainer   session name, or $null
#   fm_backend_zellij_pane_for_tab            Get-FmBackendZellijPaneForTab         pane id, or ''
#   fm_backend_zellij_tab_for_pane            Get-FmBackendZellijTabForPane         tab id, or ''
#   fm_backend_zellij_pane_exists             Test-FmBackendZellijPaneExists        [bool]
#   fm_backend_zellij_tab_matches_label       Test-FmBackendZellijTabLabel          [bool]
#   fm_backend_zellij_create_task             New-FmBackendZellijTask               "<tab> <pane>", or $null
#   fm_backend_zellij_parse_target            Split-FmBackendZellijTarget           @{Ok;Session;Pane}
#   fm_backend_zellij_target_ready            Test-FmBackendZellijTargetReady       [bool]
#   fm_backend_zellij_current_path            Get-FmBackendZellijCurrentPath        path, or ''
#   fm_backend_zellij_send_literal            Send-FmBackendZellijLiteral           [bool]
#   fm_backend_zellij_normalize_key           ConvertTo-FmBackendZellijKey          zellij key name
#   fm_backend_zellij_send_key                Send-FmBackendZellijKey               [bool]
#   fm_backend_zellij_send_text_line          Send-FmBackendZellijTextLine          [bool]
#   fm_backend_zellij_capture                 Get-FmBackendZellijCapture            text, or $null
#   fm_backend_zellij_send_text_submit        Send-FmBackendZellijTextSubmit        verdict string
#   fm_backend_zellij_kill                    Remove-FmBackendZellijTarget          [bool]
#   fm_backend_zellij_list_live               Get-FmBackendZellijLiveTask           [string[]] TSV records
#   fm_backend_zellij_resolve_bare_selector   Resolve-FmBackendZellijBareSelector   target, or $null
#
# ---------------------------------------------------------------------------
# THE EMPIRICAL FINDINGS THIS ADAPTER IS SHAPED BY (real zellij 0.44.0;
# docs/zellij-backend.md holds the evidence log). Every one of them survives the
# conversion because each is a property of ZELLIJ, not of bash:
#
#   1. `zellij action <sub>` ALWAYS EXITS 0 - even against a nonexistent session
#      (it prints the session list to stdout and an error to stderr) or a
#      nonexistent pane id (it prints nothing at all, to neither stream). THE
#      EXIT CODE CAN NEVER BE TRUSTED TO DETECT A BAD TARGET. Every op therefore
#      verifies session liveness first through a passive list-sessions query,
#      verifies the pane still appears in list-panes, and validates output SHAPE
#      (a bare integer tab id, JSON that parses) rather than a status.
#   2. Every pane-targeting action MUST pass an explicit --pane-id. The "focused
#      pane" default is unreliable: a fresh session auto-opens a floating
#      plugin pane that starts FOCUSED and shadows the real terminal pane, so a
#      pane-id-less send silently goes nowhere.
#   3. Key names are zellij's own: Enter is "Enter", Escape is "Esc" (NOT
#      "Escape"), and Ctrl-C is the single argument "Ctrl c" WITH an embedded
#      space - "C-c", "Ctrl+c" and two separate argv words were all verified to
#      fail.
#   4. `pane_cwd` does NOT track a subshell, so worktree discovery uses an
#      active pwd-marker probe instead of passive polling.
#   5. `new-tab` steals focus with no suppression flag, so the previously active
#      tab is captured before and restored after.
#   6. Closing a tab's only pane leaves a GHOST TAB, so kill resolves the owning
#      tab and calls close-tab-by-id.
#   7. Tab names are NOT unique, so the duplicate check is ours - and titles are
#      home-scoped ("fm-<hometag>-<id>") because every firstmate home shares one
#      session's tab bar. A legacy untagged tab is still matched, but ONLY when
#      exactly one live tab carries that bare name.
#
# ---------------------------------------------------------------------------
# WHAT THIS TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. jq DISAPPEARS. Every `| jq ...` becomes ConvertFrom-Json -AsHashtable in
#    process. The jq semantics that carry meaning are reproduced exactly:
#    `.[]?` tolerates a payload that is not an array (yielding nothing rather
#    than erroring, which is what makes the always-exit-0 CLI's "session not
#    found" text fall through harmlessly); `head -1` takes the FIRST match; and
#    `--argjson` parses its argument as JSON, so a non-numeric tab or pane id
#    makes jq fail and the whole pipeline yield nothing.
# 2. THE CLI IS RESOLVED, NEVER NAMED - Process.Start does not search PATH.
#    Resolved per call so a suite that changes PATH between cases is honoured.
# 3. ZELLIJ_SESSION_NAME IS SET AROUND THE CALL AND RESTORED. The bash twin sets
#    it as a command prefix; PowerShell has no such scoping, so it is set and
#    restored in a finally. Both the env var and the global --session flag are
#    still sent, exactly as the twin does for defence in depth.
# 4. `nohup ... &` HAS NO TWIN. Initialize-FmBackendZellijServer starts the
#    session detached and polls for it, which is what the bash twin's
#    backgrounded launch plus poll loop amounts to; the launch's own exit status
#    is never inspected in either world, because an "already exists" failure is
#    harmless and existence is what actually gets checked.
#
# WINDOWS NOTE: zellij has no verified Windows path and is not installed on this
# host, so NO path in this file has been exercised against a real zellij. The
# live behaviour a captain on Windows reaches is the missing-CLI refusal, which
# IS exercised directly; everything past it is faithful-by-reading and driven
# through a fake CLI in tests/fm-backends-other-psm1.test.sh.
#
# Imported through bin/fm-backend.psm1:
#   Import-FmBackendAdapter zellij

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports; see bin/fm-composer-lib.psm1 for why.
Import-Module (Join-Path $PSScriptRoot '..' 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-backend-hometag-lib.psm1')

$script:FmZellijOrdinal = [System.StringComparison]::Ordinal

# Verified minimum: 0.44 for returned pane/tab ids and dump-screen --pane-id.
$script:FmZellijMinMajor = 0
$script:FmZellijMinMinor = 44

# --- identity -----------------------------------------------------------------

<#
.SYNOPSIS
The zellij session this spawn or op uses.
.DESCRIPTION
Twin of fm_backend_zellij_session. FM_ZELLIJ_SESSION is the ambient-selection
knob an operator or an isolated test harness sets; absent means the shared
"firstmate" session. Never use it alone for destructive test cleanup -
tests/zellij-test-safety.sh owns and guards that path.
#>
function Get-FmBackendZellijSession {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_ZELLIJ_SESSION' -Default 'firstmate')
}

<#
.SYNOPSIS
This installation's home tag, used to scope tab titles.
.DESCRIPTION
Twin of fm_backend_zellij_home_label. Zellij has ONE session-global tab
namespace shared by every firstmate home, so the tag is what stops two homes
whose task ids collide from sending to, peeking at, or closing each other's tabs.
#>
function Get-FmBackendZellijHomeLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmBackendHomeTag)
}

<#
.SYNOPSIS
The actual tab title a new task's tab is created with.
.DESCRIPTION
Twin of fm_backend_zellij_scoped_title: the caller-facing "fm-<id>" label,
home-tagged as "fm-<hometag>-<id>". A label that does not start with "fm-" is
tagged whole.
#>
function Get-FmBackendZellijScopedTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')

    if ($null -eq $Label) { $Label = '' }
    # NOT $home: that is a READONLY automatic variable, and assigning to it
    # throws at runtime rather than merely tripping the linter.
    $tag = Get-FmBackendZellijHomeLabel
    $rest = if ($Label.StartsWith('fm-', $script:FmZellijOrdinal)) { $Label.Substring(3) } else { $Label }
    return "fm-$tag-$rest"
}

# --- tool and version gates ---------------------------------------------------

<#
.SYNOPSIS
Refuse loudly when zellij or jq is missing.
.DESCRIPTION
Twin of fm_backend_zellij_tool_check, including both exact refusals. THIS is the
path a captain on a host without zellij actually reaches.

jq is still required even though this module no longer uses it: the bash twin
that shares these homes does, and a home that would fail under bash must not
silently appear healthy under PowerShell.
#>
function Test-FmBackendZellijTool {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmCommand 'zellij')) {
        Write-FmErr "error: backend=zellij selected but the 'zellij' CLI is not installed (https://zellij.dev)"
        return $false
    }
    if (-not (Test-FmCommand 'jq')) {
        Write-FmErr "error: backend=zellij selected but 'jq' is not installed (required to parse zellij's JSON output)"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Refuse loudly on a missing or too-old zellij client.
.DESCRIPTION
Twin of fm_backend_zellij_version_check. The version is the SECOND
whitespace-separated field of `zellij --version` ("zellij 0.44.0"), must contain
only digits and dots, and a non-numeric major or minor degrades to 0 rather than
throwing - so a build like "0.x" is refused as too old instead of crashing.
#>
function Test-FmBackendZellijVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmBackendZellijTool)) { return $false }
    $result = Invoke-FmBackendZellijRaw @('--version')
    if (-not $result.Ok) {
        Write-FmErr "error: 'zellij --version' failed; is zellij installed correctly?"
        return $false
    }
    $raw = $result.StdOut.TrimEnd([char]10)
    # `awk '{print $2}'`: the second field of the FIRST record, split on runs of
    # whitespace with leading whitespace ignored.
    $firstLine = $raw.Split("`n")[0]
    $fields = @($firstLine -split '[ \t]+' | Where-Object { $_ -ne '' })
    $ver = if ($fields.Count -ge 2) { $fields[1] } else { '' }
    if ($ver -eq '' -or $ver -notmatch '^[0-9.]+$') {
        Write-FmErr "error: could not parse a zellij version from '$raw'; refusing to use an unverified zellij build"
        return $false
    }

    $parts = @($ver.Split('.'))
    $major = 0
    $minor = 0
    if ($parts.Count -ge 1 -and $parts[0] -match '^[0-9]+$') { $major = [int]$parts[0] }
    if ($parts.Count -ge 2 -and $parts[1] -match '^[0-9]+$') { $minor = [int]$parts[1] }
    if ($major -lt $script:FmZellijMinMajor -or
        ($major -eq $script:FmZellijMinMajor -and $minor -lt $script:FmZellijMinMinor)) {
        Write-FmErr "error: zellij $ver is older than the verified minimum $($script:FmZellijMinMajor).$($script:FmZellijMinMinor); update zellij before using backend=zellij"
        return $false
    }
    return $true
}

# --- the CLI seam -------------------------------------------------------------

# A bare `zellij ...` with no session routing - used only by --version and
# list-sessions, which are session-independent.
function Invoke-FmBackendZellijRaw {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $resolved = Get-Command 'zellij' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $resolved) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = 'fm: zellij not found on PATH'; Ok = $false }
    }
    try {
        return Invoke-FmTool -FilePath $resolved.Source -Arguments @($Arguments)
    } catch {
        return @{ ExitCode = 127; StdOut = ''; StdErr = "fm: zellij failed to start: $($_.Exception.Message)"; Ok = $false }
    }
}

<#
.SYNOPSIS
Run `zellij --session <session> <args...>` with the session env var also set.
.DESCRIPTION
Twin of fm_backend_zellij_cli. BOTH routing mechanisms are used together, as the
bash twin does for defence in depth: the leading GLOBAL --session flag (zellij's
session-target flag comes before the subcommand, unlike herdr's trailing one)
and the ZELLIJ_SESSION_NAME environment variable.

The env var is set around the call and restored afterwards, because PowerShell
has no command-prefix scoping. Restoring matters: leaving it set would silently
re-route a later call whose session differs.
#>
function Invoke-FmBackendZellijCli {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $had = [Environment]::GetEnvironmentVariable('ZELLIJ_SESSION_NAME')
    try {
        [Environment]::SetEnvironmentVariable('ZELLIJ_SESSION_NAME', $Session)
        return Invoke-FmBackendZellijRaw (@('--session', $Session) + @($Arguments))
    } finally {
        [Environment]::SetEnvironmentVariable('ZELLIJ_SESSION_NAME', $had)
    }
}

<#
.SYNOPSIS
Passive, READ-ONLY session liveness check.
.DESCRIPTION
Twin of fm_backend_zellij_session_exists, and deliberately never starts or
creates anything. Unlike herdr - whose server restart is non-destructive -
zellij's kill-session is destructive, so recreating an unrelated session under
the same name would silently orphan whatever the caller actually meant to reach.
`grep -qxF`: a fixed-string WHOLE-LINE match.
#>
function Test-FmBackendZellijSessionExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb, not to a plural noun. These names are the direct twins of the bash predicates they replace and are what makes the pairing greppable from either tree; renaming them to satisfy a spelling heuristic would break that.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $result = Invoke-FmBackendZellijRaw @('list-sessions', '--short', '--no-formatting')
    if (-not $result.Ok) { return $false }
    $body = $result.StdOut.TrimEnd([char]10)
    if ($body -eq '') { return $false }
    foreach ($line in $body.Split("`n")) {
        if ([string]::Equals($line, $Session, $script:FmZellijOrdinal)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Create the named session in the background, headless, if it does not exist.
.DESCRIPTION
Twin of fm_backend_zellij_server_ensure. The launch's own exit status is never
inspected in either world - running it against an existing session prints
"Session already exists" and exits 1, which is harmless because existence is
checked first and what actually decides success is the poll below.
#>
function Initialize-FmBackendZellijServer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    if (Test-FmBackendZellijSessionExists $Session) { return $true }
    $null = Invoke-FmBackendZellijRaw @('attach', '-b', $Session)
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-FmBackendZellijSessionExists $Session) { return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-FmErr "error: zellij session '$Session' did not come up within 10s"
    return $false
}

<#
.SYNOPSIS
The full spawn-time container-ensure sequence.
.DESCRIPTION
Twin of fm_backend_zellij_container_ensure: version gate, then session. Returns
the session name - there is no second "workspace" component, because zellij has
no such concept.
#>
function Initialize-FmBackendZellijContainer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-FmBackendZellijVersion)) { return $null }
    $session = Get-FmBackendZellijSession
    if (-not (Initialize-FmBackendZellijServer $session)) { return $null }
    return $session
}

# --- jq replacements ----------------------------------------------------------

# `.[]?` over a JSON payload: yields the array's elements, and yields NOTHING
# for anything that is not an array. That tolerance is load-bearing here - the
# always-exit-0 CLI prints a plain-text session list on a bad session, and this
# is what makes that fall through harmlessly instead of erroring.
function Get-FmBackendZellijJsonArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Json = '')

    if ([string]::IsNullOrEmpty($Json)) { return @() }
    $data = $null
    # -NoEnumerate is required, not cosmetic: ConvertFrom-Json writes the
    # elements of a TOP-LEVEL JSON array to the pipeline one at a time, so a
    # single-element array would arrive as a bare object and read as 'not an
    # array' - silently yielding nothing for a session with exactly one tab.
    try { $data = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate } catch { return ,@() }
    # `,` is load-bearing, not style: a bare `return @()` from a
    # PowerShell function arrives at the caller as $null, so an empty JSON
    # array would be indistinguishable from an absent field - and the
    # caller would then fall through to a text field the twin ignores, or
    # throw reading .Count on $null.
    if ($data -is [System.Collections.IList]) { return ,@($data) }
    return ,@()
}

# `--argjson x "$v"`: the argument is parsed as JSON, so a non-numeric id makes
# jq fail outright and the pipeline yields nothing. $null means "jq would have
# failed", which every caller maps to an empty result.
function ConvertTo-FmBackendZellijJsonNumber {
    [CmdletBinding()]
    [OutputType([System.Nullable[double]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value = '')

    if ([string]::IsNullOrEmpty($Value)) { return $null }
    [double]$parsed = 0
    $ok = [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
    if (-not $ok) { return $null }
    return $parsed
}

# Numeric equality against a jq --argjson value, tolerating the entry's own
# field being absent or non-numeric.
function Test-FmBackendZellijNumberEquals {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb, not to a plural noun. These names are the direct twins of the bash predicates they replace and are what makes the pairing greppable from either tree; renaming them to satisfy a spelling heuristic would break that.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Entry,
        [Parameter(Position = 1)][string]$Name,
        [Parameter(Position = 2)][AllowNull()][object]$Wanted
    )

    if ($null -eq $Wanted) { return $false }
    if (-not ($Entry -is [System.Collections.IDictionary]) -or -not $Entry.Contains($Name)) { return $false }
    $v = $Entry[$Name]
    if ($null -eq $v) { return $false }
    try { return ([double]$v -eq [double]$Wanted) } catch { return $false }
}

function Test-FmBackendZellijIsTerminalPane {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object]$Entry)

    if (-not ($Entry -is [System.Collections.IDictionary]) -or -not $Entry.Contains('is_plugin')) { return $false }
    # `select(.is_plugin == false)`: the literal JSON false, not merely falsy.
    return ($Entry['is_plugin'] -is [bool] -and -not [bool]$Entry['is_plugin'])
}

function Get-FmBackendZellijField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Entry,
        [Parameter(Position = 1)][string]$Name
    )

    if (-not ($Entry -is [System.Collections.IDictionary]) -or -not $Entry.Contains($Name)) { return '' }
    $v = $Entry[$Name]
    if ($null -eq $v) { return '' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return [string]$v }
    return [System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture)
}

# --- pane and tab lookups -----------------------------------------------------

<#
.SYNOPSIS
The terminal (non-plugin) pane id for a tab.
.DESCRIPTION
Twin of fm_backend_zellij_pane_for_tab, taking the FIRST match (`head -1`).
Terminal pane ids are a SEPARATE numbering namespace from plugin pane ids, which
is why a plugin pane and a terminal pane can share a bare id and why the
is_plugin filter is not optional. Never assumes a tab-position/pane-number
correspondence.
#>
function Get-FmBackendZellijPaneForTab {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TabId = ''
    )

    $wanted = ConvertTo-FmBackendZellijJsonNumber $TabId
    if ($null -eq $wanted) { return '' }
    $result = Invoke-FmBackendZellijCli $Session @('action', 'list-panes', '--json')
    foreach ($entry in (Get-FmBackendZellijJsonArray $result.StdOut)) {
        if ((Test-FmBackendZellijNumberEquals $entry 'tab_id' $wanted) -and
            (Test-FmBackendZellijIsTerminalPane $entry)) {
            return (Get-FmBackendZellijField $entry 'id')
        }
    }
    return ''
}

<#
.SYNOPSIS
The owning tab id for a pane - the reverse lookup kill needs.
.DESCRIPTION
Twin of fm_backend_zellij_tab_for_pane. Meta stores only the pane in the target
string; the tab id is looked up FRESH rather than trusted stale, mirroring the
never-trust-a-stored-id recovery posture every adapter shares.
#>
function Get-FmBackendZellijTabForPane {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $wanted = ConvertTo-FmBackendZellijJsonNumber $PaneId
    if ($null -eq $wanted) { return '' }
    $result = Invoke-FmBackendZellijCli $Session @('action', 'list-panes', '--json')
    foreach ($entry in (Get-FmBackendZellijJsonArray $result.StdOut)) {
        if ((Test-FmBackendZellijNumberEquals $entry 'id' $wanted) -and
            (Test-FmBackendZellijIsTerminalPane $entry)) {
            return (Get-FmBackendZellijField $entry 'tab_id')
        }
    }
    return ''
}

<#
.SYNOPSIS
Does this terminal pane still appear in the session's pane list?
.DESCRIPTION
Twin of fm_backend_zellij_pane_exists - the structural liveness check that
substitutes for an exit code the CLI never provides (finding 1).
#>
function Test-FmBackendZellijPaneExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb, not to a plural noun. These names are the direct twins of the bash predicates they replace and are what makes the pairing greppable from either tree; renaming them to satisfy a spelling heuristic would break that.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $wanted = ConvertTo-FmBackendZellijJsonNumber $PaneId
    if ($null -eq $wanted) { return $false }
    $result = Invoke-FmBackendZellijCli $Session @('action', 'list-panes', '--json')
    foreach ($entry in (Get-FmBackendZellijJsonArray $result.StdOut)) {
        if ((Test-FmBackendZellijNumberEquals $entry 'id' $wanted) -and
            (Test-FmBackendZellijIsTerminalPane $entry)) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Does this tab carry the title firstmate expects for a task label?
.DESCRIPTION
Twin of fm_backend_zellij_tab_matches_label. The home-scoped tagged title is
checked first - what every NEW tab is created with. A tab created before
home-scoping shipped carries the bare label, and that IS still accepted, but
ONLY when it is unambiguous: exactly one live tab in the whole session carries
that bare name.

The ambiguity rule is the safety rule. A bare name shared by two live tabs - this
home's own pre-migration tab and, say, a same-named tab from a different
firstmate home sharing this one zellij session - REFUSES rather than trusting
whichever happened to match, because the two worlds would otherwise disagree
about whose task is whose.

One list-tabs call serves all three checks, so a fake-CLI fixture supplying
exactly one list-tabs response keeps working unchanged.
#>
function Test-FmBackendZellijTabLabel {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TabId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Label = ''
    )

    $wanted = ConvertTo-FmBackendZellijJsonNumber $TabId
    if ($null -eq $wanted) { return $false }
    $scoped = Get-FmBackendZellijScopedTitle $Label
    $result = Invoke-FmBackendZellijCli $Session @('action', 'list-tabs', '--json')
    $tabs = Get-FmBackendZellijJsonArray $result.StdOut

    foreach ($entry in $tabs) {
        if ((Test-FmBackendZellijNumberEquals $entry 'tab_id' $wanted) -and
            [string]::Equals((Get-FmBackendZellijField $entry 'name'), $scoped, $script:FmZellijOrdinal)) {
            return $true
        }
    }

    $bareOnThisTab = $false
    foreach ($entry in $tabs) {
        if ((Test-FmBackendZellijNumberEquals $entry 'tab_id' $wanted) -and
            [string]::Equals((Get-FmBackendZellijField $entry 'name'), $Label, $script:FmZellijOrdinal)) {
            $bareOnThisTab = $true
            break
        }
    }
    if (-not $bareOnThisTab) { return $false }

    $count = 0
    foreach ($entry in $tabs) {
        if ([string]::Equals((Get-FmBackendZellijField $entry 'name'), $Label, $script:FmZellijOrdinal)) { $count++ }
    }
    return ($count -eq 1)
}

# --- lifecycle ----------------------------------------------------------------

<#
.SYNOPSIS
Create the task's tab, refusing an existing title.
.DESCRIPTION
Twin of fm_backend_zellij_create_task. Returns "<tab_id> <pane_id>", or $null
after the twin's refusal.

Two behaviours worth keeping in view. The duplicate check is OURS - zellij does
not enforce tab-name uniqueness. And the created tab id is validated as a BARE
INTEGER before being used, which is what rejects the always-exit-0 CLI's
"session not found" text: without that shape check a nonexistent session would
yield a "tab id" made of prose.

Focus-steal mitigation, a verified finding with no upstream suppression flag:
new-tab unconditionally focuses the created tab for every attached client, so
the previously active tab is captured before and restored after. Best-effort - a
failure to restore never fails the spawn.
#>
function New-FmBackendZellijTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Label = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Cwd = ''
    )

    if (-not (Test-FmBackendZellijSessionExists $Session)) {
        Write-FmErr "error: zellij session '$Session' does not exist; run container_ensure first"
        return $null
    }
    $title = Get-FmBackendZellijScopedTitle $Label
    $listed = Invoke-FmBackendZellijCli $Session @('action', 'list-tabs', '--json')
    $tabs = Get-FmBackendZellijJsonArray $listed.StdOut

    foreach ($entry in $tabs) {
        if ([string]::Equals((Get-FmBackendZellijField $entry 'name'), $title, $script:FmZellijOrdinal)) {
            Write-FmErr "error: zellij tab '$title' already exists in session '$Session'"
            return $null
        }
    }

    $prevActive = ''
    foreach ($entry in $tabs) {
        if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('active') -and
            $entry['active'] -is [bool] -and [bool]$entry['active']) {
            $prevActive = Get-FmBackendZellijField $entry 'tab_id'
            break
        }
    }

    $created = Invoke-FmBackendZellijCli $Session @('action', 'new-tab', '--cwd', $Cwd, '--name', $title)
    # `tr -d '[:space:]'`: every whitespace byte, not merely the trailing newline.
    $tabId = ($created.StdOut -replace '[ \t\n\v\f\r]', '')
    if ($tabId -eq '' -or $tabId -notmatch '^[0-9]+$') {
        Write-FmErr "error: zellij new-tab did not return a numeric tab id for '$title' (got '$tabId'; session '$Session' may not exist)"
        return $null
    }

    $paneId = Get-FmBackendZellijPaneForTab $Session $tabId
    if ($paneId -eq '') {
        Write-FmErr "error: could not find a terminal pane for zellij tab $tabId (session '$Session')"
        return $null
    }
    if ($prevActive -ne '' -and -not [string]::Equals($prevActive, $tabId, $script:FmZellijOrdinal)) {
        $null = Invoke-FmBackendZellijCli $Session @('action', 'go-to-tab-by-id', $prevActive)
    }
    return "$tabId $paneId"
}

<#
.SYNOPSIS
Split "<session>:<pane-id>" on the FIRST colon.
.DESCRIPTION
Twin of fm_backend_zellij_parse_target, which publishes its two halves in shell
globals because a bash function cannot return three values. Returns
@{ Ok; Session; Pane } instead. Ok is false unless BOTH halves are non-empty and
a colon was actually present.
#>
function Split-FmBackendZellijTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if ($null -eq $Target) { $Target = '' }
    $colon = $Target.IndexOf(':')
    if ($colon -lt 0) { return @{ Ok = $false; Session = $Target; Pane = $Target } }
    $session = $Target.Substring(0, $colon)
    $pane = $Target.Substring($colon + 1)
    return @{ Ok = ($session -ne '' -and $pane -ne ''); Session = $session; Pane = $pane }
}

<#
.SYNOPSIS
Parse a target and verify its session and pane are alive.
.DESCRIPTION
Twin of fm_backend_zellij_target_ready. When the caller knows the owning task
label, the pane's TAB is verified against that label before the numeric pane id
is trusted - the numeric id alone means nothing once tabs can be recreated.
Returns @{ Ok; Session; Pane } so a caller gets the parsed halves with the
verdict, matching how the bash twin leaves its globals set.
#>
function Resolve-FmBackendZellijTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $parsed = Split-FmBackendZellijTarget $Target
    if (-not $parsed.Ok) { return @{ Ok = $false; Session = $parsed.Session; Pane = $parsed.Pane } }
    if (-not (Test-FmBackendZellijSessionExists $parsed.Session)) {
        return @{ Ok = $false; Session = $parsed.Session; Pane = $parsed.Pane }
    }
    if (-not [string]::IsNullOrEmpty($ExpectedLabel)) {
        $tabId = Get-FmBackendZellijTabForPane $parsed.Session $parsed.Pane
        if ($tabId -eq '') { return @{ Ok = $false; Session = $parsed.Session; Pane = $parsed.Pane } }
        $ok = Test-FmBackendZellijTabLabel $parsed.Session $tabId $ExpectedLabel
        return @{ Ok = $ok; Session = $parsed.Session; Pane = $parsed.Pane }
    }
    $ok = Test-FmBackendZellijPaneExists $parsed.Session $parsed.Pane
    return @{ Ok = $ok; Session = $parsed.Session; Pane = $parsed.Pane }
}

<#
.SYNOPSIS
Boolean view of the target-readiness check, for the dispatcher.
.DESCRIPTION
The name bin/fm-backend.psm1's Test-FmBackendTargetExists probes for.
#>
function Test-FmBackendZellijTargetReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )
    return [bool](Resolve-FmBackendZellijTarget $Target $ExpectedLabel).Ok
}

# --- reads and writes ---------------------------------------------------------

<#
.SYNOPSIS
Bounded plain-text pane capture.
.DESCRIPTION
Twin of fm_backend_zellij_capture. dump-screen has no --lines bound, so routine
reads of 40 lines or fewer use the current viewport and larger explicit reads
use --full scrollback, trimmed locally to the last N lines. On a very short
viewport a small read can legitimately see fewer lines than requested.

A non-numeric or empty line count degrades to 40 rather than failing. Returns
$null when the target is not ready or the CLI failed.
#>
function Get-FmBackendZellijCapture {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendZellijTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $null }
    $count = 40
    if ($Lines -match '^[0-9]+$') { $count = [int]$Lines }

    # NOT $args: that is a PowerShell automatic variable, and assigning to it
    # inside a function is both a lint finding and a real hazard.
    $cliArgs = @('action', 'dump-screen', '--pane-id', $ready.Pane)
    if ($count -gt 40) { $cliArgs += '--full' }
    $result = Invoke-FmBackendZellijCli $ready.Session $cliArgs
    if (-not $result.Ok) { return $null }

    # `printf '%s' "$out" | tail -n N` over a value that already lost its
    # trailing newline to `$( ... )`, so the result carries none either.
    $body = $result.StdOut.TrimEnd([char]10)
    if ($body -eq '') { return '' }
    $all = @($body.Split("`n"))
    if ($all.Count -le $count) { return ($all -join "`n") }
    return (@($all[($all.Count - $count)..($all.Count - 1)]) -join "`n")
}

<#
.SYNOPSIS
Send text as literal, unsubmitted input via bracketed paste.
.DESCRIPTION
Twin of fm_backend_zellij_send_literal. `action paste` does NOT auto-submit and
uses bracketed-paste mode, which is what keeps a popup-sensitive harness safe -
the same property tmux gets from `send-keys -l`.
#>
function Send-FmBackendZellijLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendZellijTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $false }
    $null = Invoke-FmBackendZellijCli $ready.Session @('action', 'paste', '--pane-id', $ready.Pane, '--', $Text)
    # The CLI always exits 0 (finding 1), so the bash twin's own status is the
    # redirect's, i.e. success. Readiness above is the real gate.
    return $true
}

<#
.SYNOPSIS
Map firstmate's key vocabulary onto zellij's verified key names.
.DESCRIPTION
Twin of fm_backend_zellij_normalize_key. Verified empirically: "Enter" and "Esc"
work, "Escape" is REJECTED as an invalid key, and Ctrl-C must be the single
argument "Ctrl c" with an embedded space. An unrecognised key passes through
unchanged, exactly as the bash twin does.
#>
function ConvertTo-FmBackendZellijKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Key = '')

    if ($null -eq $Key) { $Key = '' }
    if ($Key -cin @('Enter', 'enter')) { return 'Enter' }
    if ($Key -cin @('Escape', 'escape', 'Esc', 'esc')) { return 'Esc' }
    if ($Key -cin @('C-c', 'c-c', 'ctrl+c', 'Ctrl+c', 'Ctrl+C', 'Ctrl c', 'ctrl c')) { return 'Ctrl c' }
    # C-u clears a composer line. fm-send's muse interrupt path needs it to drop
    # the prompt muse restores into the composer after Escape.
    if ($Key -cin @('C-u', 'c-u', 'ctrl+u', 'Ctrl+u', 'Ctrl+U', 'Ctrl u', 'ctrl u')) { return 'Ctrl u' }
    return $Key
}

<#
.SYNOPSIS
Send one named special key at an EXPLICIT pane id.
.DESCRIPTION
Twin of fm_backend_zellij_send_key. The explicit --pane-id is not optional: the
ambient "focused pane" default is shadowed by a floating plugin pane on a fresh
session, so a pane-id-less send silently goes nowhere (finding 2).
#>
function Send-FmBackendZellijKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendZellijTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $false }
    $normalized = ConvertTo-FmBackendZellijKey $Key
    $null = Invoke-FmBackendZellijCli $ready.Session @('action', 'send-keys', '--pane-id', $ready.Pane, $normalized)
    return $true
}

<#
.SYNOPSIS
Send one line of text and submit it.
.DESCRIPTION
Twin of fm_backend_zellij_send_text_line. Zellij has no atomic run-and-submit
primitive, so this composes paste + send-keys Enter - the ONLY form available
here, unlike tmux and herdr.
#>
function Send-FmBackendZellijTextLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Send-FmBackendZellijLiteral $Target $Text $ExpectedLabel)) { return $false }
    return (Send-FmBackendZellijKey $Target 'Enter' $ExpectedLabel)
}

<#
.SYNOPSIS
The live pane's working directory, through an active marker probe.
.DESCRIPTION
Twin of fm_backend_zellij_current_path, and NOT a passive field read for a
verified reason: `pane_cwd` reflects a `cd` run directly in the pane's own shell
but stays FROZEN at wherever that shell was when it launched `treehouse get` as
a foreground command - it never follows that command's internal cd into the
acquired worktree. Zellij exposes no live-process cwd field and no per-pane pid,
so passive polling cannot answer this at all.

So the pane is asked: print PWD between two unique markers, settle, capture, and
read only the marked line. Scoped to fm-spawn's own worktree-discovery poll,
where injecting a harmless extra command before the harness launches is an
acceptable trade for a reliable answer. Returns '' - never an error - on every
failure path, because the caller polls.
#>
function Get-FmBackendZellijCurrentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $begin = '__FM_ZELLIJ_CWD_BEGIN__'
    $end = '__FM_ZELLIJ_CWD_END__'
    if (-not (Test-FmBackendZellijTargetReady $Target $ExpectedLabel)) { return '' }
    $probe = "printf '%s\n' '$begin'; pwd; printf '%s\n' '$end'"
    if (-not (Send-FmBackendZellijTextLine $Target $probe $ExpectedLabel)) { return '' }
    Start-Sleep -Milliseconds 300
    $out = Get-FmBackendZellijCapture $Target '200' $ExpectedLabel
    if ($null -eq $out) { return '' }
    return (Get-FmBackendMarkedPath $out $begin $end)
}

# Shared by the zellij and cmux current-path probes, whose bash twins are
# byte-identical. Concatenates every line BETWEEN the markers (a wrapped path is
# split across capture rows) and keeps the LAST block that looks absolute.
function Get-FmBackendMarkedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '',
        [Parameter(Position = 1)][string]$BeginMarker,
        [Parameter(Position = 2)][string]$EndMarker
    )

    if ([string]::IsNullOrEmpty($Capture)) { return '' }
    $ordinal = [System.StringComparison]::Ordinal
    $split = ($Capture + "`n").Split("`n")
    $inBlock = $false
    $chunk = ''
    $last = ''
    foreach ($line in @($split[0..($split.Length - 2)])) {
        if ([string]::Equals($line, $BeginMarker, $ordinal)) { $inBlock = $true; $chunk = ''; continue }
        if ([string]::Equals($line, $EndMarker, $ordinal)) {
            if ($chunk.StartsWith('/', $ordinal)) { $last = $chunk }
            $inBlock = $false
            continue
        }
        if ($inBlock) { $chunk += $line }
    }
    return $last
}

<#
.SYNOPSIS
Type text once, then retry Enter until the pane visibly changes.
.DESCRIPTION
Twin of fm_backend_zellij_send_text_submit, and the one adapter that confirms
submission by CONTENT DIFF rather than by reading a composer: zellij's CLI
exposes no cursor-row or ANSI capture primitive to classify with.

Capture right after typing as the TYPED baseline, then after each Enter. No
change means the Enter was swallowed, so retry - Enter only, never retyping,
because a retyped instruction would be delivered twice to a live agent.

The diff is also the load-bearing defence against the always-exit-0 CLI: a truly
dead target never shows a change, so it correctly reports pending rather than a
false "sent".
#>
function Send-FmBackendZellijTextSubmit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$Settle = '0',
        [Parameter(Position = 5)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Send-FmBackendZellijLiteral $Target $Text $ExpectedLabel)) { return 'send-failed' }
    Wait-FmBackendZellijInterval $Settle
    $typed = Get-FmBackendZellijCapture $Target '6' $ExpectedLabel
    if ($null -eq $typed) { return 'unknown' }

    [int]$budget = 0
    if (-not [int]::TryParse($Retries, [ref]$budget)) { $budget = 0 }
    $i = 0
    while ($true) {
        $null = Send-FmBackendZellijKey $Target 'Enter' $ExpectedLabel
        Wait-FmBackendZellijInterval $EnterSleep
        $after = Get-FmBackendZellijCapture $Target '6' $ExpectedLabel
        if ($null -eq $after) { return 'unknown' }
        if (-not [string]::Equals($after, $typed, $script:FmZellijOrdinal)) { return 'empty' }
        $i++
        if ($i -ge $budget) { return 'pending' }
    }
}

function Wait-FmBackendZellijInterval {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds = '')
    if ([string]::IsNullOrEmpty($Seconds)) { return }
    [double]$value = 0
    $ok = [double]::TryParse($Seconds, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $ok -or $value -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Round($value * 1000))
}

<#
.SYNOPSIS
Remove the task's tab, best-effort.
.DESCRIPTION
Twin of fm_backend_zellij_kill. Closing a tab's only PANE does not close the tab
- an empty ghost tab survives - so the owning tab is resolved fresh from the
pane and closed with close-tab-by-id, which removes pane and tab in one call.

Any resolved tab id is verified against the expected label when one is supplied,
and the recorded fallback tab id (which teardown passes for an already-empty
ghost tab) is used only when it is numeric AND either no label was supplied or
it matches. When a label was supplied but nothing verified, NOTHING is closed -
refusing beats closing a tab that may belong to another home.
#>
function Remove-FmBackendZellijTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$FallbackTabId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $parsed = Split-FmBackendZellijTarget $Target
    if (-not $parsed.Ok) { return $true }
    if (-not (Test-FmBackendZellijSessionExists $parsed.Session)) { return $true }

    $tabId = Get-FmBackendZellijTabForPane $parsed.Session $parsed.Pane
    if ($tabId -ne '' -and -not [string]::IsNullOrEmpty($ExpectedLabel) -and
        -not (Test-FmBackendZellijTabLabel $parsed.Session $tabId $ExpectedLabel)) {
        $tabId = ''
    }
    if ($FallbackTabId -match '^[0-9]+$' -and $tabId -eq '') {
        if ([string]::IsNullOrEmpty($ExpectedLabel) -or
            (Test-FmBackendZellijTabLabel $parsed.Session $FallbackTabId $ExpectedLabel)) {
            $tabId = $FallbackTabId
        }
    }

    if ($tabId -ne '') {
        $null = Invoke-FmBackendZellijCli $parsed.Session @('action', 'close-tab-by-id', $tabId)
    } elseif ([string]::IsNullOrEmpty($ExpectedLabel)) {
        $null = Invoke-FmBackendZellijCli $parsed.Session @('action', 'close-pane', '--pane-id', $parsed.Pane)
    }
    return $true
}

<#
.SYNOPSIS
Every live task tab belonging to THIS firstmate home.
.DESCRIPTION
Twin of fm_backend_zellij_list_live. Returns "<session>:<pane_id>`t<fm-id>"
records - the home tag is stripped back off, so callers see the same plain label
they always have.

This sweep deliberately does NOT attempt the legacy-bare-title fallback that
Test-FmBackendZellijTabLabel allows for a single already-known tab: telling
"our own pre-migration tab" apart from "another home's same-shaped bare title"
in a bulk sweep with no numeric id in hand is not something this adapter can do
safely. A pre-migration task stays reachable through its recorded metadata,
which target-ready and kill DO accept via that fallback.
#>
function Get-FmBackendZellijLiveTask {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $records = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-FmBackendZellijSessionExists $Session)) { return @($records) }
    $prefix = 'fm-' + (Get-FmBackendZellijHomeLabel) + '-'
    $listed = Invoke-FmBackendZellijCli $Session @('action', 'list-tabs', '--json')
    foreach ($entry in (Get-FmBackendZellijJsonArray $listed.StdOut)) {
        $name = Get-FmBackendZellijField $entry 'name'
        if (-not $name.StartsWith($prefix, $script:FmZellijOrdinal)) { continue }
        $tabId = Get-FmBackendZellijField $entry 'tab_id'
        if ($tabId -eq '') { continue }
        $plain = $name.Substring($prefix.Length)
        if ($plain -eq '') { continue }
        $paneId = Get-FmBackendZellijPaneForTab $Session $tabId
        if ($paneId -eq '') { continue }
        $records.Add("$Session`:$paneId`tfm-$plain")
    }
    return @($records)
}

<#
.SYNOPSIS
Find an ad hoc tab by name across every active session.
.DESCRIPTION
Twin of fm_backend_zellij_resolve_bare_selector. The home-scoped title is tried
first across every session; only then is an exact BARE name accepted, and only
when exactly one tab across every active session carries it. Ambiguity refuses.

Rare in practice - zellij tasks normally carry metadata - and deliberately NOT
wired into the dispatcher's own selector resolution, which stays tmux-only.
#>
function Resolve-FmBackendZellijBareSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    $scoped = Get-FmBackendZellijScopedTitle $Name
    $listed = Invoke-FmBackendZellijRaw @('list-sessions', '--short', '--no-formatting')
    $sessions = @()
    if ($listed.Ok) {
        $body = $listed.StdOut.TrimEnd([char]10)
        if ($body -ne '') { $sessions = @($body.Split("`n") | Where-Object { $_ -ne '' }) }
    }

    foreach ($session in $sessions) {
        $tabs = Get-FmBackendZellijJsonArray (Invoke-FmBackendZellijCli $session @('action', 'list-tabs', '--json')).StdOut
        foreach ($entry in $tabs) {
            if (-not [string]::Equals((Get-FmBackendZellijField $entry 'name'), $scoped, $script:FmZellijOrdinal)) { continue }
            $tabId = Get-FmBackendZellijField $entry 'tab_id'
            if ($tabId -eq '') { continue }
            $paneId = Get-FmBackendZellijPaneForTab $session $tabId
            if ($paneId -eq '') { continue }
            return "$session`:$paneId"
        }
    }

    $count = 0
    $bareSession = ''
    $bareTabId = ''
    foreach ($session in $sessions) {
        $tabs = Get-FmBackendZellijJsonArray (Invoke-FmBackendZellijCli $session @('action', 'list-tabs', '--json')).StdOut
        foreach ($entry in $tabs) {
            if (-not [string]::Equals((Get-FmBackendZellijField $entry 'name'), $Name, $script:FmZellijOrdinal)) { continue }
            $tabId = Get-FmBackendZellijField $entry 'tab_id'
            if ($tabId -eq '') { continue }
            $count++
            if ($count -eq 1) { $bareSession = $session; $bareTabId = $tabId }
        }
    }
    if ($count -eq 1) {
        $paneId = Get-FmBackendZellijPaneForTab $bareSession $bareTabId
        if ($paneId -ne '') { return "$bareSession`:$paneId" }
    }

    Write-FmErr "error: no zellij tab named $Name in any active session"
    return $null
}

Export-ModuleMember -Function @(
    'Get-FmBackendZellijSession', 'Get-FmBackendZellijHomeLabel', 'Get-FmBackendZellijScopedTitle',
    'Test-FmBackendZellijTool', 'Test-FmBackendZellijVersion',
    'Invoke-FmBackendZellijRaw', 'Invoke-FmBackendZellijCli',
    'Test-FmBackendZellijSessionExists', 'Initialize-FmBackendZellijServer',
    'Initialize-FmBackendZellijContainer',
    'Get-FmBackendZellijPaneForTab', 'Get-FmBackendZellijTabForPane',
    'Test-FmBackendZellijPaneExists', 'Test-FmBackendZellijTabLabel',
    'New-FmBackendZellijTask', 'Split-FmBackendZellijTarget',
    'Resolve-FmBackendZellijTarget', 'Test-FmBackendZellijTargetReady',
    'Get-FmBackendZellijCapture', 'Get-FmBackendZellijCurrentPath', 'Get-FmBackendMarkedPath',
    'Send-FmBackendZellijLiteral', 'ConvertTo-FmBackendZellijKey', 'Send-FmBackendZellijKey',
    'Send-FmBackendZellijTextLine', 'Send-FmBackendZellijTextSubmit',
    'Remove-FmBackendZellijTarget', 'Get-FmBackendZellijLiveTask',
    'Resolve-FmBackendZellijBareSelector'
)
