# bin/backends/cmux.psm1 - the cmux session-provider adapter (EXPERIMENTAL).
#
# Twin: bin/backends/cmux.sh
#
# cmux is a session provider ONLY, exactly like herdr and zellij: treehouse
# stays the worktree provider. cmux has no "session" layer to multiplex - there
# is just the running app - so the container shape is ONE workspace PER TASK
# with exactly one surface inside it, and workspace titles are home-scoped
# inside this adapter because that namespace is app-global.
#
# Target string shape: "<workspace_uuid>:<surface_uuid>", neither half
# containing a colon, so splitting on the FIRST colon is unambiguous.
#
# Bash -> PowerShell map, with each function's RETURN CONVENTION:
#
#   bin/backends/cmux.sh                    this file                            returns
#   --------------------------------------  -----------------------------------  ----------------------
#   fm_backend_cmux_bin                     Get-FmBackendCmuxBinary              binary token, or $null
#   fm_backend_cmux_tool_check              Test-FmBackendCmuxTool               [bool] + stderr
#   fm_backend_cmux_password                Get-FmBackendCmuxPassword            password, or ''
#   fm_backend_cmux_cli                     Invoke-FmBackendCmuxCli              Invoke-FmTool hashtable
#   fm_backend_cmux_version_check           Test-FmBackendCmuxVersion            [bool] + stderr
#   fm_backend_cmux_ping_state              Get-FmBackendCmuxPingState           ok|denied|unauth|down|error
#   fm_backend_cmux_refuse_denied           Write-FmBackendCmuxDeniedRefusal     (stderr only)
#   fm_backend_cmux_refuse_unauth           Write-FmBackendCmuxUnauthRefusal     (stderr only)
#   fm_backend_cmux_ensure_running          Initialize-FmBackendCmuxApp          [bool]
#   fm_backend_cmux_container_ensure        Initialize-FmBackendCmuxContainer    [bool]
#   fm_backend_cmux_home_label              Get-FmBackendCmuxHomeLabel           home tag
#   fm_backend_cmux_scoped_title            Get-FmBackendCmuxScopedTitle         tagged title
#   fm_backend_cmux_workspace_id_for_label  Get-FmBackendCmuxWorkspaceForLabel   workspace id, or ''
#   fm_backend_cmux_surface_id_for_workspace Get-FmBackendCmuxSurfaceForWorkspace surface id, or ''
#   fm_backend_cmux_create_task             New-FmBackendCmuxTask                "<ws> <surface>", or $null
#   fm_backend_cmux_parse_target            Split-FmBackendCmuxTarget            @{Ok;Workspace;Surface}
#   fm_backend_cmux_surface_exists          Test-FmBackendCmuxSurfaceExists      [bool]
#   fm_backend_cmux_target_ready            Test-FmBackendCmuxTargetReady        [bool]
#   fm_backend_cmux_current_path            Get-FmBackendCmuxCurrentPath         path, or ''
#   fm_backend_cmux_send_literal            Send-FmBackendCmuxLiteral            [bool]
#   fm_backend_cmux_normalize_key           ConvertTo-FmBackendCmuxKey           cmux key name
#   fm_backend_cmux_send_key                Send-FmBackendCmuxKey                [bool]
#   fm_backend_cmux_send_text_line          Send-FmBackendCmuxTextLine           [bool]
#   fm_backend_cmux_capture                 Get-FmBackendCmuxCapture             text, or $null
#   fm_backend_cmux_composer_state          Get-FmBackendCmuxComposerState       empty|pending|unknown
#   fm_backend_cmux_send_text_submit        Send-FmBackendCmuxTextSubmit         verdict string
#   fm_backend_cmux_window_of_workspace     Get-FmBackendCmuxWindowOfWorkspace   @{Window;Count}
#   fm_backend_cmux_kill                    Remove-FmBackendCmuxTarget           [bool]
#   fm_backend_cmux_list_live               Get-FmBackendCmuxLiveTask            [string[]] TSV records
#
# ---------------------------------------------------------------------------
# THE EMPIRICAL FINDINGS THIS ADAPTER IS SHAPED BY (real cmux 0.64.17;
# docs/cmux-backend.md holds the evidence log). Each is a property of CMUX, so
# each survives the conversion unchanged:
#
#   1. `send` does NOT auto-submit, matching every other backend's
#      literal-then-separate-Enter contract.
#   2. Surface cwd is CREATION-TIME-FROZEN, not live-tracking: it never follows
#      a foreground subshell's own cd, which is exactly what `treehouse get`
#      does. Worktree discovery therefore uses an active pwd-marker probe.
#   3. `read-screen` against a genuinely FRESH surface that has never been
#      written to fails outright, for every --lines value and no matter how long
#      you wait, until at least one `send` has written to it. That ruled it out
#      as the liveness probe - the very first send on a new task would fail its
#      own pre-flight check - so list-panes is the liveness primitive instead.
#   4. Closing a workspace's LAST surface REFUSES with a typed error, and
#      close-workspace silently no-ops on the last workspace in its window. So
#      kill creates a throwaway sibling first when the target is last, which is
#      cmux's own "closed the last tab" outcome.
#   5. Workspace ids do NOT survive an app relaunch, so recovery matches by
#      scoped TITLE and never by a stored uuid.
#   6. NO title uniqueness is enforced for workspaces or surfaces, so the
#      duplicate check is ours - over home-scoped titles, so a shared cmux app
#      cannot cross-match another firstmate home's task.
#
#   And the socket-mode finding that shapes every refusal here: the control
#   socket defaults to cmuxOnly, which REJECTS any CLI not spawned inside cmux.
#   firstmate always drives cmux from an external shell, so the mode must be
#   automation (recommended), password, or allowAll; off and cmuxOnly can never
#   work externally. That is why an auth failure fails FAST with an actionable
#   pointer instead of retry-looping - relaunching cannot fix a config problem.
#
# ---------------------------------------------------------------------------
# WHAT THIS TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. THE SOCKET PASSWORD IS STILL READ FRESH PER CALL, AND STILL NEVER
#    OVERRIDES AN AMBIENT ONE. This is the single most delicate behaviour in the
#    file. CMUX_SOCKET_PASSWORD is exported ONLY when config/cmux-socket-password
#    resolves to a non-empty value; when the file is absent or blank, the
#    operator's own ambient CMUX_SOCKET_PASSWORD is left exactly as it was.
#    Setting it to an empty string would be WORSE than not setting it - it would
#    replace a working operator password with nothing and turn a healthy home
#    into an auth failure. PowerShell has no command-prefix scoping, so the two
#    variables are set and RESTORED around each call in a finally block.
# 2. jq DISAPPEARS, but its `//` operator is NOT JavaScript's `||`: jq falls
#    through only for null and false, so an EMPTY-STRING selected_surface_id is
#    kept rather than skipped. Get-FmBackendCmuxJsonAlternative is that rule.
# 3. THE BINARY TOKEN IS PRESERVED VERBATIM. The bash twin prints the bare word
#    `cmux` when the CLI is on PATH and the absolute bundle path otherwise, and
#    this returns the same two answers - the CLI seam resolves the bare word
#    through Get-Command when it has to, because Process.Start does not search
#    PATH.
# 4. `open -a cmux` IS macOS-ONLY AND STAYS THAT WAY. It is invoked as the twin
#    invokes it; on a host with no `open` the launch simply fails and the twin's
#    own refusal is printed, which is the correct outcome for a macOS-only app.
#
# WINDOWS NOTE: cmux is macOS-only BY CONSTRUCTION, so no path in this file can
# ever be exercised against a real cmux here. The live behaviour a captain on
# Windows reaches is the missing-CLI refusal, which IS exercised directly;
# everything past it is faithful-by-reading and driven through a fake CLI in
# tests/fm-backends-other-psm1.test.sh.
#
# Imported through bin/fm-backend.psm1:
#   Import-FmBackendAdapter cmux

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports; see bin/fm-composer-lib.psm1 for why.
Import-Module (Join-Path $PSScriptRoot '..' 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-composer-lib.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-backend-hometag-lib.psm1')

$script:FmCmuxOrdinal = [System.StringComparison]::Ordinal
$script:FmCmuxMinMajor = 0
$script:FmCmuxMinMinor = 64

# --- binary resolution --------------------------------------------------------

<#
.SYNOPSIS
Resolve the cmux CLI, preferring PATH over the app bundle.
.DESCRIPTION
Twin of fm_backend_cmux_bin, and it returns the SAME TWO ANSWERS: the bare word
`cmux` when the CLI is on PATH, or the absolute bundle path when only that
exists. $null when neither does.

cmux does not reliably land on PATH after a plain app install - it ships an
OPTIONAL "install CLI" action that a fresh install has not necessarily run - so
PATH is preferred (it respects an operator who ran that action) with the
well-known bundle path as the fallback.
#>
function Get-FmBackendCmuxBinary {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-FmCommand 'cmux') { return 'cmux' }
    $bundle = Get-FmEnv -Name 'FM_BACKEND_CMUX_BUNDLE_BIN' `
        -Default '/Applications/cmux.app/Contents/Resources/bin/cmux'
    $native = ConvertTo-FmNativePath $bundle
    if ([System.IO.File]::Exists($native)) { return $bundle }
    return $null
}

<#
.SYNOPSIS
Refuse loudly when the cmux CLI or jq is missing.
.DESCRIPTION
Twin of fm_backend_cmux_tool_check, including both exact refusals. THIS is the
path a captain on a host without cmux actually reaches, and the refusal names
the bundle path it also looked at so the message is actionable.

jq is still required even though this module no longer uses it: the bash twin
sharing these homes does, and a home that would fail under bash must not
silently appear healthy under PowerShell.
#>
function Test-FmBackendCmuxTool {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq (Get-FmBackendCmuxBinary)) {
        $bundle = Get-FmEnv -Name 'FM_BACKEND_CMUX_BUNDLE_BIN' `
            -Default '/Applications/cmux.app/Contents/Resources/bin/cmux'
        Write-FmErr "error: backend=cmux selected but the 'cmux' CLI was not found on PATH or at $bundle (https://cmux.com)"
        return $false
    }
    if (-not (Test-FmCommand 'jq')) {
        Write-FmErr "error: backend=cmux selected but 'jq' is not installed (required to parse cmux's JSON output)"
        return $false
    }
    return $true
}

# --- the socket password, and the CLI seam ------------------------------------

<#
.SYNOPSIS
The optional socket password from config/cmux-socket-password.
.DESCRIPTION
Twin of fm_backend_cmux_password: the FIRST non-empty line of the file, read
FRESH from the effective config dir on every call, or '' when the file is absent
or holds nothing.

The line is returned VERBATIM, with no trimming - a password of spaces is a
password. Only a genuinely empty line is skipped.
#>
function Get-FmBackendCmuxPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configDir = Get-FmEnv -Name 'FM_CONFIG_OVERRIDE'
    if ([string]::IsNullOrEmpty($configDir)) {
        $configDir = Join-Path ((Get-FmContext $PSScriptRoot).Home) 'config'
    }
    $file = Join-Path (ConvertTo-FmNativePath $configDir) 'cmux-socket-password'
    if (-not [System.IO.File]::Exists($file)) { return '' }
    # Split on LF ONLY, keeping any CR: bash `read -r` keeps it too, so a
    # CRLF password file yields the same (equally broken) value in both
    # worlds rather than one world silently repairing it.
    $text = Get-FmFileText $file
    if ($text -eq '') { return '' }
    $split = $text.Split([char]10)
    $count = $split.Length
    # A trailing LF terminates the last line rather than starting an empty one.
    if ($count -gt 0 -and $split[$count - 1] -eq '') { $count-- }
    for ($i = 0; $i -lt $count; $i++) {
        if ($split[$i] -ne '') { return $split[$i] }
    }
    return ''
}

<#
.SYNOPSIS
Run one `cmux` command, quieted, with the socket password only when configured.
.DESCRIPTION
Twin of fm_backend_cmux_cli. CMUX_QUIET is always set (it suppresses legacy-alias
notices that would otherwise pollute parsed output).

CMUX_SOCKET_PASSWORD IS SET ONLY WHEN ONE IS ACTUALLY CONFIGURED. That is the
whole point of the two branches in the bash twin, and it must not be collapsed:
exporting an EMPTY password would clobber an operator's own ambient
CMUX_SOCKET_PASSWORD and turn a working home into an auth failure. Because
PowerShell has no command-prefix scoping, both variables are restored in a
finally block - so a call never leaves the password behind for anything else in
the process either.
#>
function Invoke-FmBackendCmuxCli {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $bin = Get-FmBackendCmuxBinary
    if ($null -eq $bin) {
        return @{ ExitCode = 1; StdOut = ''; StdErr = 'fm: cmux CLI not found'; Ok = $false }
    }
    # The bash twin prints the bare word `cmux` for the PATH case; Process.Start
    # does not search PATH, so the bare word is resolved here and nowhere else.
    $filePath = $bin
    if ([string]::Equals($bin, 'cmux', $script:FmCmuxOrdinal)) {
        $resolved = Get-Command 'cmux' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $resolved) {
            return @{ ExitCode = 1; StdOut = ''; StdErr = 'fm: cmux CLI not found'; Ok = $false }
        }
        $filePath = $resolved.Source
    } else {
        $filePath = ConvertTo-FmNativePath $bin
    }

    $password = Get-FmBackendCmuxPassword
    $hadQuiet = [Environment]::GetEnvironmentVariable('CMUX_QUIET')
    $hadPassword = [Environment]::GetEnvironmentVariable('CMUX_SOCKET_PASSWORD')
    try {
        [Environment]::SetEnvironmentVariable('CMUX_QUIET', '1')
        if ($password -ne '') {
            [Environment]::SetEnvironmentVariable('CMUX_SOCKET_PASSWORD', $password)
        }
        return Invoke-FmTool -FilePath $filePath -Arguments @($Arguments)
    } catch {
        return @{ ExitCode = 1; StdOut = ''; StdErr = "fm: cmux failed to start: $($_.Exception.Message)"; Ok = $false }
    } finally {
        [Environment]::SetEnvironmentVariable('CMUX_QUIET', $hadQuiet)
        if ($password -ne '') {
            [Environment]::SetEnvironmentVariable('CMUX_SOCKET_PASSWORD', $hadPassword)
        }
    }
}

<#
.SYNOPSIS
Refuse loudly on a missing or too-old cmux client.
.DESCRIPTION
Twin of fm_backend_cmux_version_check. `cmux version` needs no socket, so this
is a pure client gate, separate from reachability and auth.
#>
function Test-FmBackendCmuxVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmBackendCmuxTool)) { return $false }
    $result = Invoke-FmBackendCmuxCli @('version')
    if (-not $result.Ok) {
        Write-FmErr "error: 'cmux version' failed; is cmux installed correctly?"
        return $false
    }
    $raw = $result.StdOut.TrimEnd([char]10)
    $firstLine = $raw.Split("`n")[0]
    $fields = @($firstLine -split '[ \t]+' | Where-Object { $_ -ne '' })
    $ver = if ($fields.Count -ge 2) { $fields[1] } else { '' }
    if ($ver -eq '' -or $ver -notmatch '^[0-9.]+$') {
        Write-FmErr "error: could not parse a cmux version from '$raw'; refusing to use an unverified cmux build"
        return $false
    }
    $parts = @($ver.Split('.'))
    $major = 0
    $minor = 0
    if ($parts.Count -ge 1 -and $parts[0] -match '^[0-9]+$') { $major = [int]$parts[0] }
    if ($parts.Count -ge 2 -and $parts[1] -match '^[0-9]+$') { $minor = [int]$parts[1] }
    if ($major -lt $script:FmCmuxMinMajor -or
        ($major -eq $script:FmCmuxMinMajor -and $minor -lt $script:FmCmuxMinMinor)) {
        Write-FmErr "error: cmux $ver is older than the verified minimum $($script:FmCmuxMinMajor).$($script:FmCmuxMinMinor); update cmux before using backend=cmux"
        return $false
    }
    return $true
}

# --- reachability and auth ----------------------------------------------------

<#
.SYNOPSIS
Classify socket reachability and auth from `cmux ping`'s own text.
.DESCRIPTION
Twin of fm_backend_cmux_ping_state: ok, denied, unauth, down or error. A
missing or rejected connection is a NORMAL expected outcome here, never treated
as a scripting bug, which is why the classification reads the text rather than
the exit status - and why stdout and stderr are merged, exactly as the twin's
`2>&1` does.

The three auth-shaped replies all classify as `unauth` because each is a
password-configuration problem on one side or the other, never something
relaunching the app can fix.
#>
function Get-FmBackendCmuxPingState {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $result = Invoke-FmBackendCmuxCli @('ping')
    $out = ($result.StdOut + $result.StdErr).TrimEnd([char]10)
    if ([string]::Equals($out, 'PONG', $script:FmCmuxOrdinal)) { return 'ok' }
    if ($out.Contains('only processes started inside cmux can connect', $script:FmCmuxOrdinal)) { return 'denied' }
    if ($out.Contains('Password mode is enabled but no socket password', $script:FmCmuxOrdinal) -or
        $out.Contains('Authentication required', $script:FmCmuxOrdinal) -or
        $out.Contains('Invalid password', $script:FmCmuxOrdinal)) { return 'unauth' }
    if ($out.Contains('Socket not found', $script:FmCmuxOrdinal)) { return 'down' }
    return 'error'
}

# The two fail-fast auth refusals, factored exactly as the bash twin factors
# them so the pre-launch and post-launch checks cannot drift. Each names every
# externally-viable socket mode plus the config/backend opt-out for a caller who
# only landed on cmux through auto-detection.
function Write-FmBackendCmuxDeniedRefusal {
    [CmdletBinding()]
    param()
    Write-FmErr "error: backend=cmux socket rejected the connection (automation.socketControlMode is cmuxOnly, the default, which never admits an external CLI like firstmate). In cmux Settings > Automation set Socket Control Mode to 'Automation mode' (recommended - same-user external clients, no password), or 'Password mode' plus config/cmux-socket-password/CMUX_SOCKET_PASSWORD, or 'Full open access' (NOT recommended - admits every local user) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux."
}

function Write-FmBackendCmuxUnauthRefusal {
    [CmdletBinding()]
    param()
    Write-FmErr "error: backend=cmux socket requires a password (automation.socketControlMode=password) but none is configured for this caller, or the configured one was rejected. Set config/cmux-socket-password or export CMUX_SOCKET_PASSWORD to the password from cmux Settings > Automation, or switch Socket Control Mode to 'Automation mode' (recommended - no password needed) - see docs/cmux-backend.md 'Setup' - or set config/backend to tmux (or pass --backend tmux) if you did not mean to use cmux."
}

<#
.SYNOPSIS
Make cmux reachable, launching it only when the socket is simply not up.
.DESCRIPTION
Twin of fm_backend_cmux_ensure_running. An auth failure is a CONFIGURATION
problem a relaunch cannot fix, so denied and unauth fail fast with an actionable
pointer instead of retry-looping; only `down` (and the unclassified `error`)
reaches the launch. A launch that never becomes reachable also names the `off`
mode, since a disabled listener is indistinguishable from a slow launch on the
wire.
#>
function Initialize-FmBackendCmuxApp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    switch -CaseSensitive (Get-FmBackendCmuxPingState) {
        'ok' { return $true }
        'denied' { Write-FmBackendCmuxDeniedRefusal; return $false }
        'unauth' { Write-FmBackendCmuxUnauthRefusal; return $false }
        default { }
    }

    # macOS-only by construction, exactly as the twin: on a host with no `open`
    # this fails and the twin's own refusal is what a captain sees.
    $open = Get-Command 'open' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $launched = $false
    if ($null -ne $open) {
        try { $launched = (Invoke-FmTool -FilePath $open.Source -Arguments @('-a', 'cmux')).Ok } catch { $launched = $false }
    }
    if (-not $launched) {
        Write-FmErr "error: failed to launch cmux ('open -a cmux' failed)"
        return $false
    }

    for ($i = 0; $i -lt 20; $i++) {
        switch -CaseSensitive (Get-FmBackendCmuxPingState) {
            'ok' { return $true }
            'denied' { Write-FmBackendCmuxDeniedRefusal; return $false }
            'unauth' { Write-FmBackendCmuxUnauthRefusal; return $false }
            default { }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-FmErr "error: cmux did not become reachable within 10s of launch. If the app is already running, its Socket Control Mode may be 'Off' (no control socket at all) - set it to 'Automation mode' (recommended) in Settings > Automation, see docs/cmux-backend.md 'Setup'."
    return $false
}

<#
.SYNOPSIS
The full spawn-time container-ensure sequence.
.DESCRIPTION
Twin of fm_backend_cmux_container_ensure: version gate, then reachability. There
is no per-home container to stand up - cmux has no session layer, the app itself
is the only container - so nothing is returned but the verdict.
#>
function Initialize-FmBackendCmuxContainer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmBackendCmuxVersion)) { return $false }
    return (Initialize-FmBackendCmuxApp)
}

# --- identity -----------------------------------------------------------------

function Get-FmBackendCmuxHomeLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmBackendHomeTag)
}

<#
.SYNOPSIS
The home-scoped workspace title for a caller-facing task label.
.DESCRIPTION
Twin of fm_backend_cmux_scoped_title. cmux has ONE app-global workspace
namespace, so the home tag is what stops a shared app from cross-matching
another firstmate home's task.
#>
function Get-FmBackendCmuxScopedTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')

    if ($null -eq $Label) { $Label = '' }
    # NOT $home: that is a READONLY automatic variable, and assigning to it
    # throws at runtime rather than merely tripping the linter.
    $tag = Get-FmBackendCmuxHomeLabel
    $rest = if ($Label.StartsWith('fm-', $script:FmCmuxOrdinal)) { $Label.Substring(3) } else { $Label }
    return "fm-$tag-$rest"
}

# --- jq replacements ----------------------------------------------------------

function ConvertFrom-FmBackendCmuxJson {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Json = '')

    if ([string]::IsNullOrEmpty($Json)) { return $null }
    # -NoEnumerate: ConvertFrom-Json writes a TOP-LEVEL array's elements to the
    # pipeline one at a time, so `list-windows` returning one window would
    # arrive as a bare hashtable and fail the IList check - which is exactly
    # how the containing window went unfound.
    try { return ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate } catch { return $null }
}

# `.<name>[]?` over a payload: the named array's elements, or nothing at all when
# the payload is not an object or the field is not an array.
function Get-FmBackendCmuxJsonList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Data,
        [Parameter(Position = 1)][string]$Name
    )

    # `,` is load-bearing, not style: a bare `return @()` from a
    # PowerShell function arrives at the caller as $null, so an empty JSON
    # array would be indistinguishable from an absent field - and the
    # caller would then fall through to a text field the twin ignores, or
    # throw reading .Count on $null.
    if (-not ($Data -is [System.Collections.IDictionary]) -or -not $Data.Contains($Name)) { return ,@() }
    $v = $Data[$Name]
    if ($v -is [System.Collections.IList]) { return ,@($v) }
    return ,@()
}

# jq's `//` ALTERNATIVE operator, which is NOT JavaScript's `||`: it falls
# through only for null and false, so an EMPTY STRING on the left is kept. That
# difference decides whether a surface whose selected id is "" resolves to ""
# (jq, and therefore this) or falls back to surface_ids[0] (a JS-style rewrite).
function Get-FmBackendCmuxJsonAlternative {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Left,
        [Parameter(Position = 1)][AllowNull()][object]$Right
    )

    if ($null -eq $Left) { return $Right }
    if ($Left -is [bool] -and -not [bool]$Left) { return $Right }
    return $Left
}

function Get-FmBackendCmuxField {
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

# --- workspace and surface lookups --------------------------------------------

<#
.SYNOPSIS
The live workspace id whose title equals this label, or ''.
.DESCRIPTION
Twin of fm_backend_cmux_workspace_id_for_label. cmux enforces no title
uniqueness, so this adopts the FIRST match, mirroring every other adapter's
duplicate posture.
#>
function Get-FmBackendCmuxWorkspaceForLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')

    $result = Invoke-FmBackendCmuxCli @('workspace', 'list', '--json', '--id-format', 'uuids')
    $data = ConvertFrom-FmBackendCmuxJson $result.StdOut
    foreach ($entry in (Get-FmBackendCmuxJsonList $data 'workspaces')) {
        if ([string]::Equals((Get-FmBackendCmuxField $entry 'title'), $Label, $script:FmCmuxOrdinal)) {
            return (Get-FmBackendCmuxField $entry 'id')
        }
    }
    return ''
}

<#
.SYNOPSIS
The surface id of a workspace's first pane, or ''.
.DESCRIPTION
Twin of fm_backend_cmux_surface_id_for_workspace, whose jq is
`.panes[0] // {} | .selected_surface_id // (.surface_ids[0] // empty)` - the
selected surface wins, else the first of the surface list, else nothing. See
Get-FmBackendCmuxJsonAlternative for why an empty-string selected id is KEPT
rather than skipped.
#>
function Get-FmBackendCmuxSurfaceForWorkspace {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = '')

    $result = Invoke-FmBackendCmuxCli @('list-panes', '--workspace', $WorkspaceId, '--json', '--id-format', 'uuids')
    $data = ConvertFrom-FmBackendCmuxJson $result.StdOut
    $panes = Get-FmBackendCmuxJsonList $data 'panes'
    $pane = if ($panes.Count -gt 0) { $panes[0] } else { @{} }

    $selected = if ($pane -is [System.Collections.IDictionary] -and $pane.Contains('selected_surface_id')) {
        $pane['selected_surface_id']
    } else { $null }
    $ids = Get-FmBackendCmuxJsonList $pane 'surface_ids'
    $firstId = if ($ids.Count -gt 0) { $ids[0] } else { $null }
    $value = Get-FmBackendCmuxJsonAlternative $selected $firstId
    if ($null -eq $value) { return '' }
    if ($value -is [bool] -and -not [bool]$value) { return '' }
    return [string]$value
}

<#
.SYNOPSIS
Does this surface currently belong to this workspace?
.DESCRIPTION
Twin of fm_backend_cmux_surface_exists - a STRUCTURAL check, never a content
read, and specifically never read-screen: read-screen against a genuinely fresh
surface fails until something has written to it (finding 3), which would make
the very first send on a new task fail its own readiness pre-check.
#>
function Test-FmBackendCmuxSurfaceExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb, not to a plural noun. These names are the direct twins of the bash predicates they replace and are what makes the pairing greppable from either tree; renaming them to satisfy a spelling heuristic would break that.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$SurfaceId = ''
    )

    $result = Invoke-FmBackendCmuxCli @('list-panes', '--workspace', $WorkspaceId, '--json', '--id-format', 'uuids')
    $data = ConvertFrom-FmBackendCmuxJson $result.StdOut
    foreach ($pane in (Get-FmBackendCmuxJsonList $data 'panes')) {
        foreach ($id in (Get-FmBackendCmuxJsonList $pane 'surface_ids')) {
            if ([string]::Equals([string]$id, $SurfaceId, $script:FmCmuxOrdinal)) { return $true }
        }
    }
    return $false
}

# --- lifecycle ----------------------------------------------------------------

<#
.SYNOPSIS
Create the task's workspace, refusing an existing live title.
.DESCRIPTION
Twin of fm_backend_cmux_create_task. Returns "<workspace_id> <surface_id>", or
$null after the twin's refusal.

The duplicate check is OURS (finding 6). A freshly created workspace already has
exactly one surface, so no separate new-surface call is needed, and --focus false
is passed for defence in depth even though it is already the default.
#>
function New-FmBackendCmuxTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Cwd = ''
    )

    $title = Get-FmBackendCmuxScopedTitle $Label
    if ((Get-FmBackendCmuxWorkspaceForLabel $title) -ne '') {
        Write-FmErr "error: cmux workspace '$title' already exists"
        return $null
    }
    $created = Invoke-FmBackendCmuxCli @(
        'new-workspace', '--name', $title, '--cwd', $Cwd, '--focus', 'false', '--id-format', 'uuids')
    if (-not $created.Ok) {
        # The twin captures BOTH streams into its error text, so a socket
        # refusal reaches the captain rather than being swallowed.
        $out = ($created.StdOut + $created.StdErr).TrimEnd([char]10)
        Write-FmErr "error: cmux new-workspace failed for '$title': $out"
        return $null
    }
    $wsid = Get-FmBackendCmuxWorkspaceForLabel $title
    if ($wsid -eq '') {
        Write-FmErr "error: could not resolve a cmux workspace id for '$title' after creation"
        return $null
    }
    $sfid = Get-FmBackendCmuxSurfaceForWorkspace $wsid
    if ($sfid -eq '') {
        Write-FmErr "error: could not resolve the default surface for cmux workspace '$title' ($wsid)"
        return $null
    }
    return "$wsid $sfid"
}

<#
.SYNOPSIS
Split "<workspace_uuid>:<surface_uuid>" on the FIRST colon.
.DESCRIPTION
Twin of fm_backend_cmux_parse_target, whose two halves live in shell globals
because a bash function cannot return three values.
#>
function Split-FmBackendCmuxTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if ($null -eq $Target) { $Target = '' }
    $colon = $Target.IndexOf(':')
    if ($colon -lt 0) { return @{ Ok = $false; Workspace = $Target; Surface = $Target } }
    $ws = $Target.Substring(0, $colon)
    $sf = $Target.Substring($colon + 1)
    return @{ Ok = ($ws -ne '' -and $sf -ne ''); Workspace = $ws; Surface = $sf }
}

<#
.SYNOPSIS
Parse a target and verify it is live, refreshing stale ids by label.
.DESCRIPTION
Twin of fm_backend_cmux_target_ready. Returns @{ Ok; Workspace; Surface } - the
REFRESHED ids when a label was supplied, because workspace ids do not survive an
app relaunch (finding 5) and the recorded target may name a workspace that no
longer exists.

The three-way branch is the careful part. When the recorded workspace still
carries the expected title, its surface is checked and the workspace kept. When
it carries a DIFFERENT title, the target is refused outright - that workspace now
belongs to something else and must never be written to. Only when the recorded
workspace is GONE is the title looked up afresh.
#>
function Resolve-FmBackendCmuxTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $parsed = Split-FmBackendCmuxTarget $Target
    if (-not $parsed.Ok) { return @{ Ok = $false; Workspace = $parsed.Workspace; Surface = $parsed.Surface } }
    if ([string]::IsNullOrEmpty($ExpectedLabel)) {
        $ok = Test-FmBackendCmuxSurfaceExists $parsed.Workspace $parsed.Surface
        return @{ Ok = $ok; Workspace = $parsed.Workspace; Surface = $parsed.Surface }
    }

    $expectedTitle = Get-FmBackendCmuxScopedTitle $ExpectedLabel
    $listed = Invoke-FmBackendCmuxCli @('workspace', 'list', '--json', '--id-format', 'uuids')
    $data = ConvertFrom-FmBackendCmuxJson $listed.StdOut
    $title = ''
    foreach ($entry in (Get-FmBackendCmuxJsonList $data 'workspaces')) {
        if ([string]::Equals((Get-FmBackendCmuxField $entry 'id'), $parsed.Workspace, $script:FmCmuxOrdinal)) {
            $title = Get-FmBackendCmuxField $entry 'title'
            break
        }
    }

    $wsid = ''
    if ([string]::Equals($title, $expectedTitle, $script:FmCmuxOrdinal)) {
        if (Test-FmBackendCmuxSurfaceExists $parsed.Workspace $parsed.Surface) {
            return @{ Ok = $true; Workspace = $parsed.Workspace; Surface = $parsed.Surface }
        }
        $wsid = $parsed.Workspace
    } elseif ($title -ne '') {
        return @{ Ok = $false; Workspace = $parsed.Workspace; Surface = $parsed.Surface }
    } else {
        $wsid = Get-FmBackendCmuxWorkspaceForLabel $expectedTitle
        if ($wsid -eq '') { return @{ Ok = $false; Workspace = $parsed.Workspace; Surface = $parsed.Surface } }
    }

    $sfid = Get-FmBackendCmuxSurfaceForWorkspace $wsid
    if ($sfid -eq '') { return @{ Ok = $false; Workspace = $parsed.Workspace; Surface = $parsed.Surface } }
    return @{ Ok = $true; Workspace = $wsid; Surface = $sfid }
}

<#
.SYNOPSIS
Boolean view of the target-readiness check, for the dispatcher.
.DESCRIPTION
The name bin/fm-backend.psm1's Test-FmBackendTargetExists probes for.
#>
function Test-FmBackendCmuxTargetReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )
    return [bool](Resolve-FmBackendCmuxTarget $Target $ExpectedLabel).Ok
}

# --- reads and writes ---------------------------------------------------------

<#
.SYNOPSIS
Bounded plain-text surface capture.
.DESCRIPTION
Twin of fm_backend_cmux_capture. "Fetch generous, trim locally": at least 200
lines are always requested even when fewer are wanted, because a single
read-screen is bounded by the surface's ACTUAL viewport height regardless of
--lines, so a caller asking for more than the viewport can show would otherwise
silently get less with no way to tell why.
#>
function Get-FmBackendCmuxCapture {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendCmuxTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $null }
    $count = 200
    if ($Lines -match '^[0-9]+$') { $count = [int]$Lines }
    $fetch = if ($count -ge 200) { $count } else { 200 }

    $result = Invoke-FmBackendCmuxCli @(
        'read-screen', '--workspace', $ready.Workspace, '--surface', $ready.Surface,
        '--scrollback', '--lines', [string]$fetch, '--json')
    if (-not $result.Ok) { return $null }
    $data = ConvertFrom-FmBackendCmuxJson $result.StdOut
    # `jq -r '.text // empty'`: an absent or null text yields nothing at all.
    $text = ''
    if ($data -is [System.Collections.IDictionary] -and $data.Contains('text')) {
        $raw = $data['text']
        if ($null -ne $raw -and -not ($raw -is [bool] -and -not [bool]$raw)) { $text = [string]$raw }
    }
    $body = $text.TrimEnd([char]10)
    if ($body -eq '') { return '' }
    $all = @($body.Split("`n"))
    if ($all.Count -le $count) { return ($all -join "`n") }
    return (@($all[($all.Count - $count)..($all.Count - 1)]) -join "`n")
}

<#
.SYNOPSIS
Send text as literal, unsubmitted input.
.DESCRIPTION
Twin of fm_backend_cmux_send_literal. `send` does NOT auto-submit (finding 1).
#>
function Send-FmBackendCmuxLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendCmuxTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $false }
    $null = Invoke-FmBackendCmuxCli @('send', '--workspace', $ready.Workspace, '--surface', $ready.Surface, '--', $Text)
    return $true
}

<#
.SYNOPSIS
Map firstmate's key vocabulary onto cmux's send-key names.
.DESCRIPTION
Twin of fm_backend_cmux_normalize_key: lowercase and hyphenated. cmux's own
vocabulary is richer, but firstmate's shared cross-backend vocabulary only needs
these three. An unrecognised key passes through unchanged, as the twin does.
#>
function ConvertTo-FmBackendCmuxKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Key = '')

    if ($null -eq $Key) { $Key = '' }
    if ($Key -cin @('Enter', 'enter')) { return 'enter' }
    if ($Key -cin @('Escape', 'escape', 'Esc', 'esc')) { return 'escape' }
    if ($Key -cin @('C-c', 'c-c', 'ctrl+c', 'Ctrl+c', 'Ctrl+C', 'ctrl-c')) { return 'ctrl-c' }
    # C-u clears a composer line. fm-send's muse interrupt path needs it to drop
    # the prompt muse restores into the composer after Escape.
    if ($Key -cin @('C-u', 'c-u', 'ctrl+u', 'Ctrl+u', 'Ctrl+U', 'ctrl-u')) { return 'ctrl-u' }
    return $Key
}

<#
.SYNOPSIS
Send one named special key.
.DESCRIPTION
Twin of fm_backend_cmux_send_key. Escape IS natively supported here, unlike
Orca, so it is wired directly rather than refused.
#>
function Send-FmBackendCmuxKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $ready = Resolve-FmBackendCmuxTarget $Target $ExpectedLabel
    if (-not $ready.Ok) { return $false }
    $normalized = ConvertTo-FmBackendCmuxKey $Key
    $null = Invoke-FmBackendCmuxCli @(
        'send-key', '--workspace', $ready.Workspace, '--surface', $ready.Surface, $normalized)
    return $true
}

<#
.SYNOPSIS
Send one line of text and submit it.
.DESCRIPTION
Twin of fm_backend_cmux_send_text_line. cmux has no atomic run-and-submit
primitive, so this composes send + send-key enter, exactly like zellij.
#>
function Send-FmBackendCmuxTextLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Send-FmBackendCmuxLiteral $Target $Text $ExpectedLabel)) { return $false }
    return (Send-FmBackendCmuxKey $Target 'Enter' $ExpectedLabel)
}

<#
.SYNOPSIS
The live surface's working directory, through an active marker probe.
.DESCRIPTION
Twin of fm_backend_cmux_current_path, for the same verified reason zellij needs
one: `current_directory` is creation-time-frozen and never follows the cd a
foreground subshell performs, and cmux exposes no live-process cwd field either.
Returns '' - never an error - on every failure path, because the caller polls.
#>
function Get-FmBackendCmuxCurrentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $begin = '__FM_CMUX_CWD_BEGIN__'
    $end = '__FM_CMUX_CWD_END__'
    if (-not (Test-FmBackendCmuxTargetReady $Target $ExpectedLabel)) { return '' }
    $probe = "printf '%s\n' '$begin'; pwd; printf '%s\n' '$end'"
    if (-not (Send-FmBackendCmuxTextLine $Target $probe $ExpectedLabel)) { return '' }
    Start-Sleep -Milliseconds 300
    $out = Get-FmBackendCmuxCapture $Target '200' $ExpectedLabel
    if ($null -eq $out) { return '' }
    return (Get-FmBackendCmuxMarkedPath $out $begin $end)
}

# The marker reader, byte-identical in intent to zellij's. Duplicated rather
# than shared because the two bash twins are duplicated too, and an adapter must
# stay importable without pulling in a sibling backend.
function Get-FmBackendCmuxMarkedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '',
        [Parameter(Position = 1)][string]$BeginMarker,
        [Parameter(Position = 2)][string]$EndMarker
    )

    if ([string]::IsNullOrEmpty($Capture)) { return '' }
    $split = ($Capture + "`n").Split("`n")
    $inBlock = $false
    $chunk = ''
    $last = ''
    foreach ($line in @($split[0..($split.Length - 2)])) {
        if ([string]::Equals($line, $BeginMarker, $script:FmCmuxOrdinal)) { $inBlock = $true; $chunk = ''; continue }
        if ([string]::Equals($line, $EndMarker, $script:FmCmuxOrdinal)) {
            if ($chunk.StartsWith('/', $script:FmCmuxOrdinal)) { $last = $chunk }
            $inBlock = $false
            continue
        }
        if ($inBlock) { $chunk += $line }
    }
    return $last
}

# --- composer -----------------------------------------------------------------

# The bordered-row finder. cmux's bash twin and Orca's are byte-identical, and so
# are these two copies - duplicated rather than shared for the same reason as
# the marker reader above. The trim uses the C-locale space set because the bash
# twins trim with `[[:space:]]` and this row decides an injection-safety verdict.
$script:FmCmuxBorderChars = [char[]]@(0x2502, 0x2503, 0x007C)
$script:FmCmuxSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)

function Get-FmBackendCmuxComposerRow {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '')

    if ([string]::IsNullOrEmpty($Capture)) { return $null }
    $split = ($Capture + "`n").Split("`n")
    $found = $null
    foreach ($line in @($split[0..($split.Length - 2)])) {
        $trimmed = $line.Trim($script:FmCmuxSpace)
        if ($trimmed.Length -lt 2) { continue }
        $first = $trimmed[0]
        $last = $trimmed[$trimmed.Length - 1]
        if ($first -ne $last) { continue }
        if ([Array]::IndexOf($script:FmCmuxBorderChars, $first) -lt 0) { continue }
        # Scanning FORWARD and keeping the LAST match, so an earlier
        # border-shaped line - scrollback, a popup frame - never outranks the
        # real bottom-anchored composer row.
        $found = $trimmed
    }
    if ($null -eq $found) { return $null }
    foreach ($ch in $script:FmCmuxBorderChars) { $found = $found.Replace([string]$ch, '') }
    return $found.Trim($script:FmCmuxSpace)
}

<#
.SYNOPSIS
Classify the cmux composer row as empty, pending or unknown.
.DESCRIPTION
Twin of fm_backend_cmux_composer_state. cmux's read-screen gives plain text with
no cursor-row primitive and no ANSI style channel, so the classifier is
border-row based: the composer row is the LAST captured line whose trimmed
content both starts and ends with the same border glyph.

A capture with NO bordered row is `unknown`, never `empty` - the fleet-wide
safety rule in this adapter's shape, because a bare dead-shell prompt has no
bordered row and so can never be mistaken for a ready-to-inject composer. A row
only ever reached through that bordered shape is handed to the shared owner with
bordered=1.
#>
function Get-FmBackendCmuxComposerState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $lines = Get-FmEnv -Name 'FM_BACKEND_CMUX_COMPOSER_LINES' -Default '20'
    $idle = Get-FmEnv -Name 'FM_BACKEND_CMUX_IDLE_RE' -Default '^Type a message\.\.\.$'

    $capture = Get-FmBackendCmuxCapture $Target $lines $ExpectedLabel
    if ($null -eq $capture) { return 'unknown' }
    $row = Get-FmBackendCmuxComposerRow $capture
    if ($null -eq $row) { return 'unknown' }
    return Get-FmComposerContentState -Bordered '1' -Content $row -IdleRegex $idle
}

<#
.SYNOPSIS
Type text once, then retry Enter until the composer row reads empty.
.DESCRIPTION
Twin of fm_backend_cmux_send_text_submit. Retries send ONLY Enter and never
retype - a retyped instruction would be delivered twice to a live agent.

Confirmation is by CLASSIFYING THE COMPOSER ROW rather than diffing the pane,
and that choice is load-bearing: a slash-command popup's first Enter can close
the popup and fill an argument-hint placeholder into the composer instead of
submitting, which a raw diff would misread as "submitted". Classifying the row
sees the placeholder as pending, so the loop correctly sends the second Enter.

Only the exact verdict `pending` continues the loop, so an `unknown` composer
never burns the retry budget against a surface nobody can read.
#>
function Send-FmBackendCmuxTextSubmit {
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

    if (-not (Split-FmBackendCmuxTarget $Target).Ok) { return 'unknown' }
    if (-not (Send-FmBackendCmuxLiteral $Target $Text $ExpectedLabel)) { return 'send-failed' }
    Wait-FmBackendCmuxInterval $Settle

    [int]$budget = 0
    if (-not [int]::TryParse($Retries, [ref]$budget)) { $budget = 0 }
    $i = 0
    while ($true) {
        $null = Send-FmBackendCmuxKey $Target 'Enter' $ExpectedLabel
        Wait-FmBackendCmuxInterval $EnterSleep
        $state = Get-FmBackendCmuxComposerState $Target $ExpectedLabel
        if (-not [string]::Equals($state, 'pending', $script:FmCmuxOrdinal)) { return $state }
        $i++
        if ($i -ge $budget) { return 'pending' }
    }
}

function Wait-FmBackendCmuxInterval {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds = '')
    if ([string]::IsNullOrEmpty($Seconds)) { return }
    [double]$value = 0
    $ok = [double]::TryParse($Seconds, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $ok -or $value -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Round($value * 1000))
}

# --- teardown -----------------------------------------------------------------

<#
.SYNOPSIS
The window containing a workspace, and how many workspaces that window holds.
.DESCRIPTION
Twin of fm_backend_cmux_window_of_workspace. `workspace list` with no --window
is scoped to the CURRENT window only, so the containing window is found by
walking every window and asking each for its own scoped list. The count comes
from that same scoped list, which is what makes it trustworthy.

Returns @{ Window; Count } with an empty Window when the workspace is not found
live.
#>
function Get-FmBackendCmuxWindowOfWorkspace {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = '')

    $miss = @{ Window = ''; Count = 0 }
    $listed = Invoke-FmBackendCmuxCli @('list-windows', '--json', '--id-format', 'uuids')
    if (-not $listed.Ok) { return $miss }
    $windows = ConvertFrom-FmBackendCmuxJson $listed.StdOut
    if (-not ($windows -is [System.Collections.IList])) { return $miss }

    foreach ($window in @($windows)) {
        $wid = Get-FmBackendCmuxField $window 'id'
        if ($wid -eq '') { continue }
        $scoped = Invoke-FmBackendCmuxCli @('workspace', 'list', '--json', '--id-format', 'uuids', '--window', $wid)
        if (-not $scoped.Ok) { continue }
        $data = ConvertFrom-FmBackendCmuxJson $scoped.StdOut
        $workspaces = Get-FmBackendCmuxJsonList $data 'workspaces'
        $member = $false
        foreach ($entry in $workspaces) {
            if ([string]::Equals((Get-FmBackendCmuxField $entry 'id'), $WorkspaceId, $script:FmCmuxOrdinal)) {
                $member = $true
                break
            }
        }
        if (-not $member) { continue }
        return @{ Window = $wid; Count = $workspaces.Count }
    }
    return $miss
}

<#
.SYNOPSIS
Remove the task's whole workspace, best-effort.
.DESCRIPTION
Twin of fm_backend_cmux_kill. A cmux task owns one workspace, so teardown
reclaims that workspace and every surface in it.

THE LAST-WORKSPACE EXCEPTION is why this is not one call. cmux keeps every
window at one workspace or more, so close-workspace on the ONLY workspace in its
window silently no-ops - it still returns OK, but the workspace stays, which is
exactly what left a selected task workspace open at teardown. close-window
cannot rescue it either: a window holding a live terminal session cannot be
closed over the control socket. The reliable primitive is close-workspace on a
NON-last workspace, so a throwaway sibling is created first when the target is
last - leaving that window a fresh default workspace, which never carries an
fm-<home>- title and so is ignored by recovery and list-live.
#>
function Remove-FmBackendCmuxTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Unused',
        Justification = 'Declared and unused on purpose, and named for what it is. The bash twin takes an ignored SECOND positional so its signature matches every other backend kill, and the expected-label argument therefore arrives THIRD; dropping the placeholder would silently shift the label into it.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Unused = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $workspace = ''
    if (-not [string]::IsNullOrEmpty($ExpectedLabel)) {
        $ready = Resolve-FmBackendCmuxTarget $Target $ExpectedLabel
        if (-not $ready.Ok) { return $true }
        $workspace = $ready.Workspace
    } else {
        $parsed = Split-FmBackendCmuxTarget $Target
        if (-not $parsed.Ok) { return $true }
        $workspace = $parsed.Workspace
    }

    $window = Get-FmBackendCmuxWindowOfWorkspace $workspace
    if ($window.Window -ne '' -and $window.Count -eq 1) {
        $null = Invoke-FmBackendCmuxCli @('new-workspace', '--window', $window.Window, '--focus', 'false', '--id-format', 'uuids')
    }
    $null = Invoke-FmBackendCmuxCli @('close-workspace', '--workspace', $workspace)
    return $true
}

<#
.SYNOPSIS
Every live task workspace belonging to THIS firstmate home.
.DESCRIPTION
Twin of fm_backend_cmux_list_live. Matches by TITLE and never by a stored uuid,
because workspace ids do not survive an app relaunch (finding 5). Returns
"<workspace_id>:<surface_id>`t<fm-id>" records; an unreachable cmux simply lists
nothing.
#>
function Get-FmBackendCmuxLiveTask {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $records = [System.Collections.Generic.List[string]]::new()
    $prefix = 'fm-' + (Get-FmBackendCmuxHomeLabel) + '-'
    $listed = Invoke-FmBackendCmuxCli @('workspace', 'list', '--json', '--id-format', 'uuids')
    if (-not $listed.Ok) { return @($records) }
    $data = ConvertFrom-FmBackendCmuxJson $listed.StdOut
    foreach ($entry in (Get-FmBackendCmuxJsonList $data 'workspaces')) {
        $title = Get-FmBackendCmuxField $entry 'title'
        if (-not $title.StartsWith($prefix, $script:FmCmuxOrdinal)) { continue }
        $wsid = Get-FmBackendCmuxField $entry 'id'
        if ($wsid -eq '') { continue }
        $plain = $title.Substring($prefix.Length)
        if ($plain -eq '') { continue }
        $sfid = Get-FmBackendCmuxSurfaceForWorkspace $wsid
        if ($sfid -eq '') { continue }
        $records.Add("$wsid`:$sfid`tfm-$plain")
    }
    return @($records)
}

Export-ModuleMember -Function @(
    'Get-FmBackendCmuxBinary', 'Test-FmBackendCmuxTool', 'Get-FmBackendCmuxPassword',
    'Invoke-FmBackendCmuxCli', 'Test-FmBackendCmuxVersion',
    'Get-FmBackendCmuxPingState', 'Write-FmBackendCmuxDeniedRefusal', 'Write-FmBackendCmuxUnauthRefusal',
    'Initialize-FmBackendCmuxApp', 'Initialize-FmBackendCmuxContainer',
    'Get-FmBackendCmuxHomeLabel', 'Get-FmBackendCmuxScopedTitle',
    'Get-FmBackendCmuxWorkspaceForLabel', 'Get-FmBackendCmuxSurfaceForWorkspace',
    'Test-FmBackendCmuxSurfaceExists', 'New-FmBackendCmuxTask',
    'Split-FmBackendCmuxTarget', 'Resolve-FmBackendCmuxTarget', 'Test-FmBackendCmuxTargetReady',
    'Get-FmBackendCmuxCapture', 'Get-FmBackendCmuxCurrentPath', 'Get-FmBackendCmuxMarkedPath',
    'Send-FmBackendCmuxLiteral', 'ConvertTo-FmBackendCmuxKey', 'Send-FmBackendCmuxKey',
    'Send-FmBackendCmuxTextLine', 'Get-FmBackendCmuxComposerRow', 'Get-FmBackendCmuxComposerState',
    'Send-FmBackendCmuxTextSubmit', 'Get-FmBackendCmuxWindowOfWorkspace',
    'Remove-FmBackendCmuxTarget', 'Get-FmBackendCmuxLiveTask'
)
