# fm-backend.psm1 - runtime-backend selection, meta helpers, selector
# resolution, and dispatch for firstmate's session-provider abstraction.
#
# Twin: bin/fm-backend.sh
#
# Design: data/fm-backend-design-d7/report.md ("Backend Interface") and
# data/fm-backend-design-d7/herdr-addendum.md ("Events as the core
# abstraction"). tmux is the verified reference backend; herdr, zellij, orca and
# cmux are EXPERIMENTAL spawn-capable backends selected only through
# `--backend`/`FM_BACKEND`/`config/backend`, plus runtime auto-detection for
# herdr and cmux. Codex App is intentionally not in the known set;
# docs/codex-app-backend.md owns that blocked-backend contract.
#
# Compatibility contract: a task's meta may omit `backend=`; every reader here
# treats that as `tmux` (Get-FmBackendOfMeta), and fm-spawn does not write
# `backend=tmux` for a default-backend task, so existing and newly spawned
# default-path metas stay byte-identical across BOTH language trees.
#
# ============================================================================
# BASH -> POWERSHELL SURFACE MAP. Four later packages grep this table, so it is
# complete rather than illustrative, and it names each function's RETURN
# CONVENTION - a bash function has one channel (stdout plus an exit status) and
# these have two.
#
#   bin/fm-backend.sh                    this file                            returns
#   -----------------------------------  -----------------------------------  ----------------------------
#   FM_BACKEND_KNOWN                     Get-FmBackendKnownName               [string[]]
#   FM_BACKEND_SPAWN                     Get-FmBackendSpawnName               [string[]]
#   fm_backend_list_contains             Test-FmBackendListContains           [bool]
#   fm_backend_is_known                  Test-FmBackendKnown                  [bool]
#   fm_backend_detect                    Get-FmBackendDetected                @{Backend; Signal}
#   fm_backend_detect_cmux_fallback      Get-FmBackendCmuxFallbackSignal      signal string, or ''
#   fm_backend_detect_cmux_app_pid       Get-FmBackendCmuxAppProcessId        pid string, or $null
#   fm_backend_detect_cmux_app_is_ancestor Test-FmBackendCmuxAppAncestor      [bool]
#   fm_backend_name                      Get-FmBackendName                    backend token
#   fm_backend_validate                  Test-FmBackendValid                  [bool] (+ stderr refusal)
#   fm_backend_validate_spawn            Test-FmBackendSpawnValid             [bool] (+ stderr refusal)
#   fm_backend_required_tools            Get-FmBackendRequiredTool            space-joined line, or $null
#   fm_backend_required_tool_available   Test-FmBackendRequiredTool           [bool]
#   fm_meta_get                          (fm-common) Get-FmMetaValue          -- see FM_META_GET below
#   fm_backend_of_meta                   Get-FmBackendOfMeta                  backend token
#   fm_backend_target_of_meta            Get-FmBackendTargetOfMeta            target, or ''
#   fm_backend_meta_exact_value          Get-FmBackendMetaExactValue          value, or $null
#   fm_backend_endpoint_atom_valid       Test-FmBackendEndpointAtom           [bool]
#   fm_backend_validate_task_endpoint    Get-FmBackendValidatedEndpoint       @{Ok; Backend; Target}
#   fm_backend_meta_for_window           Get-FmBackendMetaForWindow           meta path, or $null
#   fm_backend_task_id_for_selector      Get-FmBackendTaskIdForSelector       task id, or $null
#   fm_backend_meta_for_selector         Get-FmBackendMetaForSelector         meta path, or $null
#   fm_backend_of_selector               Get-FmBackendOfSelector              backend token
#   fm_backend_expected_label_of_selector Get-FmBackendExpectedLabelOfSelector label, or ''
#   fm_backend_source                    Import-FmBackendAdapter              [bool]
#   fm_backend_resolve_selector          Resolve-FmBackendSelector            target, or $null
#   fm_backend_capture                   Get-FmBackendCapture                 RAW capture text, or $null
#   fm_backend_send_key                  Send-FmBackendKey                    [bool]
#   fm_backend_send_text_submit          Send-FmBackendTextSubmit             verdict string, or $null
#   fm_backend_kill                      Remove-FmBackendTarget               [bool]
#   fm_backend_remove_worktree           Remove-FmBackendWorktree             [bool]
#   fm_backend_worktree_path             Get-FmBackendWorktreePath            path, or $null
#   fm_backend_busy_state                Get-FmBackendBusyState               busy|idle|unknown
#   fm_backend_composer_state            Get-FmBackendComposerState           empty|pending|pending-unproven|unknown
#   fm_backend_target_exists             Test-FmBackendTargetExists           [bool]
#   fm_backend_agent_state               Get-FmBackendAgentState              alive|dead|missing|ambiguous|unreadable|unverified
#   fm_backend_agent_alive               Get-FmBackendAgentAlive              alive|dead|unknown
#   fm_backend_has_push                  Test-FmBackendHasPush                [bool]
#   fm_backend_events_capable            Test-FmBackendEventsCapable          [bool]
#   fm_backend_wait_transition           Wait-FmBackendTransition             @{Code; Record}
#   fm_backend_commit_transition         Save-FmBackendTransition             [bool]
#   fm_backend_clear_transition          Clear-FmBackendTransition            [bool]
#   FM_BACKEND_DETECTED/_DETECT_SIGNAL   (folded into Get-FmBackendDetected)
#   FM_BACKEND_VALIDATED_BACKEND/_TARGET (folded into Get-FmBackendValidatedEndpoint)
#
# FM_META_GET HAS NO TWIN HERE, DELIBERATELY. bin/fm-backend.sh defines
# fm_meta_get, and several libraries call it WITHOUT sourcing this file - the
# undeclared-dependency class in docs/powershell-port-inventory.md R4.
# bin/fm-common.psm1 already ships Get-FmMetaValue with byte-identical
# semantics: the LAST matching line wins, the value is everything after the
# FIRST '=' (so a value may itself contain '='), and a missing file yields an
# empty string with no error. Writing a second implementation here would create
# exactly the drift this port exists to prevent, so every reader in this file
# calls fm-common's, and a consumer that needs it imports fm-common - which
# every converted module already does. bin/fm-busy-lib.psm1's seam table records
# the same decision from the other side.
#
# THE TWO GLOBAL-VARIABLE PAIRS ARE FOLDED INTO RETURN VALUES. A bash function
# returns through stdout, and a caller capturing stdout runs it in a SUBSHELL
# where assignments cannot escape - which is the only reason fm_backend_detect
# and fm_backend_validate_task_endpoint publish their second and third values in
# globals, and why fm_backend_name's comment has to warn that it calls
# fm_backend_detect "directly (not in a command substitution)". PowerShell has
# no subshell boundary, so those values travel back in one hashtable and the
# globals are gone (the same collapse bin/fm-psproc-lib.psm1 applied to
# FM_NATIVE_PID_IMAGE/FM_NATIVE_PID_PATH).
#
# ============================================================================
# ADAPTER LOADING, AND WHAT AN UNCONVERTED ADAPTER DOES
#
# fm_backend_source lazily `source`s one adapter into the caller's single shell
# scope, guarded by a per-adapter sourced-once flag. Import-FmBackendAdapter is
# its twin and does the same thing twice on purpose:
#
#   Import-Module <adapter>            -> into THIS module's scope, so the
#                                         dispatchers below can call it;
#   Import-Module <adapter> -Global    -> into the session, so a consumer that
#                                         called Import-FmBackendAdapter can
#                                         then call Get-FmBackendTmuxCapture
#                                         directly, exactly as a bash caller can
#                                         call fm_backend_tmux_capture after
#                                         fm_backend_source.
#
# That second import is the faithful twin of `source`, not a convenience: the
# real-tmux smoke suite and several entrypoints call adapter functions directly
# after asking the dispatcher to load the adapter. Verified on this host that a
# -Global import performed inside a module function does publish to the global
# session state, and that a later Get-Command finds it.
#
# NEITHER import uses -Force. A nested Import-Module -Force REMOVES the module
# globally before reloading it, which would strip a consumer of commands it had
# already imported (verified live; bin/fm-composer-lib.psm1 carries the same
# note).
#
# UNTIL AN ADAPTER IS CONVERTED, ITS BACKEND FAILS CLOSED. A .psm1 cannot import
# a .sh, so a backend whose PowerShell adapter does not exist yet is refused
# LOUDLY with a message naming the missing file, and every dispatcher below
# returns its own degraded verdict rather than reaching a half-defined
# interface. That is resolution (b) of docs/powershell-port-inventory.md R3,
# scoped to the transition: this package converts tmux, and each later package
# lights up its backend by adding bin/backends/<name>.psm1 with the functions
# named in EXPECTED ADAPTER SURFACE below - no change is needed here.
#
# EXPECTED ADAPTER SURFACE, so the later packages write matching names. Each
# adapter is imported by Import-FmBackendAdapter and must export the arms its
# backend appears in below:
#
#   dispatcher                  tmux (this package)                herdr / zellij / orca / cmux
#   --------------------------  ---------------------------------  --------------------------------------
#   Get-FmBackendCapture        Get-FmBackendTmuxCapture           Get-FmBackend<X>Capture
#   Send-FmBackendKey           Send-FmBackendTmuxKey              Send-FmBackend<X>Key
#   Send-FmBackendTextSubmit    Send-FmBackendTmuxTextSubmit       Send-FmBackend<X>TextSubmit
#   Remove-FmBackendTarget      Remove-FmBackendTmuxTarget         Remove-FmBackend<X>Target
#   Remove-FmBackendWorktree    --                                 Remove-FmBackendOrcaWorktree
#   Get-FmBackendWorktreePath   --                                 Get-FmBackendOrcaWorktreePath
#   Get-FmBackendBusyState      --                                 Get-FmBackendHerdrBusyState
#   Get-FmBackendComposerState  Get-FmTmuxComposerState            Get-FmBackend{Herdr,Orca,Cmux}ComposerState
#   Test-FmBackendTargetExists  (direct tmux read, no adapter)     Invoke-FmBackendHerdrCli,
#                                                                  Test-FmBackend{Zellij,Cmux}TargetReady,
#                                                                  Get-FmBackendOrcaCapture
#   Get-FmBackendAgentState     Get-FmBackendTmuxAgentState        Get-FmBackendHerdrAgentState
#   Test-FmBackendEventsCapable --                                 Test-FmBackendHerdrEventsCapable
#   Wait-FmBackendTransition    --                                 Wait-FmBackendHerdrTransition
#   Save-FmBackendTransition    --                                 Save-FmBackendHerdrTransition
#   Clear-FmBackendTransition   --                                 Clear-FmBackendHerdrTransition
#   Test-FmBackendRequiredTool  --                                 Get-FmBackendCmuxBinary
#
# ============================================================================
# OTHER DELIBERATE DIVERGENCES
#
# 1. THE CONFIG DIRECTORY IS RESOLVED PER CALL, NOT PINNED AT LOAD.
#    fm-backend.sh binds FM_BACKEND_CONFIG_DIR once, at source time, and its own
#    test suite has to set that shell variable directly because a later
#    FM_CONFIG_OVERRIDE does not re-bind it. Get-FmBackendName instead resolves
#    fresh on every call - FM_BACKEND_CONFIG_DIR, then FM_CONFIG_OVERRIDE, then
#    the home's config dir - and also accepts -ConfigDir. The precedence and the
#    resulting answer are identical for any process that sets its environment
#    before the first call, which is every real firstmate process; the
#    difference only shows for a process that CHANGES the environment after
#    loading, where reading fresh is the more correct of the two.
#
# 2. THE ADAPTER SOURCED-ONCE FLAGS ARE MODULE STATE, not shell variables named
#    _FM_BACKEND_<X>_SOURCED. Nothing outside fm-backend.sh reads those, so the
#    rename costs no compatibility.
#
# 3. `uname`, `lsappinfo` AND THE ANCESTRY WALK. The cmux fallback signals are
#    macOS-only in both worlds. `uname` and `lsappinfo` are resolved through
#    Get-Command and run as real child processes, exactly as bash runs them; the
#    ancestry walk reads the NATIVE process table through bin/fm-psproc-lib.psm1
#    instead of shelling out to `ps` per hop, which is faster and, on this
#    platform, the only thing that could work at all. See the WINDOWS
#    VERIFICATION note below for what that means for testing.
#
# 4. GLOB ORDER. fm_backend_meta_for_window iterates `"$state"/*.meta`, and a
#    bash glob is SORTED. .NET enumeration order is not guaranteed, so the
#    listing is sorted ordinally before the scan - otherwise two ambiguous metas
#    naming the same window could resolve differently in the two worlds.
#
# WINDOWS VERIFICATION. tmux does not exist on Windows and cmux is macOS-only,
# so on this host: every selection, meta, validation, selector and dispatch path
# is exercised differentially by tests/fm-backend-core-psm1.test.sh through a
# fake tmux (and a fake uname/lsappinfo) on PATH; the process-ancestry cmux
# fallback is NOT, because it reads the real process table and cannot be faked
# on the PowerShell side the way the bash twin fakes `ps`.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit imports, not a reliance on the caller having imported them: a .psm1
# resolves function names in its OWN scope. fm-tmux-lib is imported for
# Invoke-FmTmuxCommand alone - Test-FmBackendTargetExists's tmux arm reads the
# pane DIRECTLY without loading the adapter (see its own comment for why), and
# "how do we invoke tmux" must have one owner rather than a second copy here.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tmux-lib.psm1')

$script:FmBackendOrdinal = [System.StringComparison]::Ordinal

# Verified backend adapters. Extend only after a backend gets its own
# bin/backends/<name>.psm1 and empirical verification, mirroring AGENTS.md
# section 4's harness-verification discipline. herdr, zellij, orca and cmux are
# EXPERIMENTAL; codex-app remains deliberately absent (docs/codex-app-backend.md).
$script:FmBackendKnown = [string[]]@('tmux', 'herdr', 'zellij', 'orca', 'cmux')
$script:FmBackendSpawn = [string[]]@('tmux', 'herdr', 'zellij', 'orca', 'cmux')
$script:FmBackendCmuxBundleId = 'com.cmuxterm.app'

# Which adapters have already been imported this process. The twin of
# _FM_BACKEND_<X>_SOURCED (divergence 2).
$script:FmBackendAdapterLoaded = @{}

# The six ASCII members of the C-locale [[:space:]], for the `tr -d '[:space:]'`
# twins below. tr is byte-oriented, so this is what it deletes.
$script:FmBackendAsciiSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)

# Named ...Name rather than ...Names because the analyzer rejects the plural
# spelling; the [string[]] return type is what says this is the whole set.
function Get-FmBackendKnownName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:FmBackendKnown
}

function Get-FmBackendSpawnName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:FmBackendSpawn
}

<#
.SYNOPSIS
Whitespace-delimited membership, without relying on word splitting.
.DESCRIPTION
Twin of fm_backend_list_contains, including the guard that a name containing
whitespace can NEVER match - a space-fenced substring test would otherwise let
"tmux herdr" match a list containing both, and fm-spawn would accept it as a
backend name.
#>
function Test-FmBackendListContains {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb Contains, not to a plural noun. The name is the direct twin of the bash fm_backend_list_contains and is what makes the pairing greppable from either tree; renaming it to satisfy a spelling heuristic would break that.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$List = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Name = ''
    )

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    foreach ($ch in $Name.ToCharArray()) {
        if ([Array]::IndexOf($script:FmBackendAsciiSpace, $ch) -ge 0) { return $false }
    }
    return (" $List ").Contains(" $Name ", $script:FmBackendOrdinal)
}

function Test-FmBackendKnown {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')
    return Test-FmBackendListContains -List ($script:FmBackendKnown -join ' ') -Name $Name
}

# --- runtime auto-detection ---------------------------------------------------

<#
.SYNOPSIS
The running cmux app's pid, resolved by bundle id through lsappinfo.
.DESCRIPTION
Twin of fm_backend_detect_cmux_app_pid. $null when lsappinfo is missing, errors,
or the app is not running (the real lsappinfo prints nothing and exits 0 in that
case, which is why an empty answer must fail rather than read as a pid).
#>
function Get-FmBackendCmuxAppProcessId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $tool = Get-Command 'lsappinfo' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $tool) { return $null }
    $result = $null
    try {
        $result = Invoke-FmTool -FilePath $tool.Source `
            -Arguments @('info', '-only', 'pid', '-app', $script:FmBackendCmuxBundleId)
    } catch {
        return $null
    }
    if (-not $result.Ok) { return $null }

    # `${out##*=}`: everything after the LAST '=' in the whole answer.
    $out = $result.StdOut.TrimEnd([char]10)
    $at = $out.LastIndexOf('=')
    if ($at -ge 0) { $out = $out.Substring($at + 1) }
    # `tr -d '[:space:]"'`
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $out.ToCharArray()) {
        if ($ch -eq '"') { continue }
        if ([Array]::IndexOf($script:FmBackendAsciiSpace, $ch) -ge 0) { continue }
        [void]$sb.Append($ch)
    }
    $pidText = $sb.ToString()
    if ($pidText -notmatch '^[0-9]+$') { return $null }
    return $pidText
}

<#
.SYNOPSIS
Does this process's parent chain reach the cmux app?
.DESCRIPTION
Twin of fm_backend_detect_cmux_app_is_ancestor: walk upward, matching either the
lsappinfo-resolved pid (bundle id, so no install path is assumed) or a
bundle-shaped command path at any install location. The walk STOPS at pid 1,
where a tmux server started from a cmux tab has already reparented - which is
why ancestry can never false-positive from inside tmux, and why the $TMUX check
winning first in Get-FmBackendDetected is what keeps that correct.

Reads the native process table through bin/fm-psproc-lib.psm1 rather than
shelling out to `ps` per hop (divergence 3).
#>
function Test-FmBackendCmuxAppAncestor {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cmuxPid = Get-FmBackendCmuxAppProcessId
    $current = [string]$PID
    $hops = 0
    while ($hops -lt 32) {
        if (-not [string]::IsNullOrEmpty($cmuxPid) -and
            [string]::Equals($current, $cmuxPid, $script:FmBackendOrdinal)) { return $true }

        $comm = Get-FmProcCommand $current
        if ($null -eq $comm) { $comm = '' }
        $comm = $comm.Trim($script:FmBackendAsciiSpace)
        if ([string]::IsNullOrEmpty($comm)) { return $false }
        # `*/cmux.app/Contents/MacOS/cmux`: a suffix match, so any install
        # location matches and nothing is hardcoded.
        if ($comm.EndsWith('/cmux.app/Contents/MacOS/cmux', $script:FmBackendOrdinal)) { return $true }

        $parent = Get-FmProcParentId $current
        if ($null -eq $parent) { return $false }
        if ([int]$parent -le 1) { return $false }
        $current = [string]$parent
        $hops++
    }
    return $false
}

<#
.SYNOPSIS
The winning cmux FALLBACK signal, or '' when neither fires.
.DESCRIPTION
Twin of fm_backend_detect_cmux_fallback. cmux's bundled `claude` PATH shim
routes through a wrapper whose passthrough path unsets every CMUX_* variable
before exec'ing the real binary, so a claude-harness firstmate launched in a
cmux tab can have NO CMUX_WORKSPACE_ID at all. When that primary marker is
absent - and only then - two macOS-only signals are consulted:

  bundle-id  __CFBundleIdentifier == com.cmuxterm.app, LaunchServices' app
             identity, inherited by every process a cmux tab spawns and NOT
             stripped by the wrapper. Authoritative in the common wrapper-strip
             case, but also inherited into every pane of a tmux server started
             from a cmux tab - the $TMUX check winning FIRST is what absorbs
             that false positive.
  ancestry   the parent chain reaches the running cmux app. Authoritative when
             the environment was scrubbed entirely; not usable from inside tmux,
             where the server has reparented - which is fine, because $TMUX
             already won there.

Cheap-first, exactly as the twin is: the bundle-id check is a pure environment
read and the ancestry walk runs only when it misses.
#>
function Get-FmBackendCmuxFallbackSignal {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $uname = Get-Command 'uname' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $uname) { return '' }
    $result = $null
    try { $result = Invoke-FmTool -FilePath $uname.Source } catch { return '' }
    # `[ "$(uname 2>/dev/null)" = Darwin ]` ignores the exit status and compares
    # the substituted output, so a non-zero uname that still printed Darwin
    # would pass in bash too.
    if (-not [string]::Equals($result.StdOut.TrimEnd([char]10), 'Darwin', $script:FmBackendOrdinal)) { return '' }

    if ([string]::Equals((Get-FmEnv -Name '__CFBundleIdentifier'), $script:FmBackendCmuxBundleId, $script:FmBackendOrdinal)) {
        return 'bundle-id'
    }
    if (Test-FmBackendCmuxAppAncestor) { return 'ancestry' }
    return ''
}

<#
.SYNOPSIS
The runtime firstmate itself is CURRENTLY executing inside, from env markers.
.DESCRIPTION
Twin of fm_backend_detect, returning @{ Backend; Signal } where an empty Backend
means nothing was detected (the bash return 1). Signal is TMUX, HERDR_ENV,
CMUX_WORKSPACE_ID, bundle-id or ancestry.

NESTING RESOLVES INNERMOST-FIRST, and the order below is the whole contract:
tmux sets $TMUX in every process running inside it - even a tmux started inside
a herdr pane - so $TMUX is checked first and wins. HERDR_ENV=1 alone selects
herdr. cmux is checked LAST because it is a terminal APPLICATION, the outermost
layer, not a session multiplexer: both tmux and herdr can run nested inside a
cmux-provided shell, but cmux cannot run nested inside either, so a tmux or
herdr marker set alongside CMUX_WORKSPACE_ID always means that multiplexer is
the innermost, currently-executing layer and must win.

CMUX_WORKSPACE_ID, not CMUX_SOCKET_PATH, is the primary cmux marker:
CMUX_SOCKET_PATH is documented as a user-settable override for pointing the CLI
at a non-default socket, so its mere presence would not reliably mean "running
inside a cmux-spawned terminal".
#>
function Get-FmBackendDetected {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if (-not [string]::IsNullOrEmpty((Get-FmEnv -Name 'TMUX'))) {
        return @{ Backend = 'tmux'; Signal = 'TMUX' }
    }
    if ([string]::Equals((Get-FmEnv -Name 'HERDR_ENV'), '1', $script:FmBackendOrdinal)) {
        return @{ Backend = 'herdr'; Signal = 'HERDR_ENV' }
    }
    if (-not [string]::IsNullOrEmpty((Get-FmEnv -Name 'CMUX_WORKSPACE_ID'))) {
        return @{ Backend = 'cmux'; Signal = 'CMUX_WORKSPACE_ID' }
    }
    $fallback = Get-FmBackendCmuxFallbackSignal
    if (-not [string]::IsNullOrEmpty($fallback)) {
        return @{ Backend = 'cmux'; Signal = $fallback }
    }
    return @{ Backend = ''; Signal = '' }
}

<#
.SYNOPSIS
The ACTIVE backend for a NEW spawn, absent an explicit per-task override.
.DESCRIPTION
Twin of fm_backend_name. Precedence: FM_BACKEND, then config/backend (a single
word on its first non-empty line, mirroring config/crew-harness), then runtime
auto-detection, then default tmux. A per-task `--backend` flag is parsed by the
caller and takes precedence over this resolution entirely; it is not read here.

Auto-detect fires ONLY when nothing was explicitly configured, so an explicit
setting always wins. Selecting herdr or cmux by auto-detect prints one loud
stderr notice because both are experimental; auto-detecting tmux stays SILENT -
that is today's default-path behavior and callers must see zero change. The cmux
notice names the winning signal, so a fallback-detected cmux is visibly distinct
from the primary-marker case.

-ConfigDir overrides where config/backend is read from; see divergence 1 in the
file header for how it and FM_BACKEND_CONFIG_DIR relate to the bash twin.
#>
function Get-FmBackendName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ConfigDir = '')

    $explicit = Get-FmEnv -Name 'FM_BACKEND'
    if (-not [string]::IsNullOrEmpty($explicit)) { return $explicit }

    if ([string]::IsNullOrEmpty($ConfigDir)) { $ConfigDir = Get-FmEnv -Name 'FM_BACKEND_CONFIG_DIR' }
    if ([string]::IsNullOrEmpty($ConfigDir)) { $ConfigDir = (Get-FmContext $PSScriptRoot).Config }
    $configFile = Join-Path (ConvertTo-FmNativePath $ConfigDir) 'backend'
    if ([System.IO.File]::Exists($configFile)) {
        foreach ($line in (Get-FmFileLines $configFile)) {
            # `tr -d '[:space:]'`, so an indented or CR-terminated value still
            # resolves - a CRLF config file is a live hazard on this platform.
            $sb = [System.Text.StringBuilder]::new()
            foreach ($ch in $line.ToCharArray()) {
                if ([Array]::IndexOf($script:FmBackendAsciiSpace, $ch) -lt 0) { [void]$sb.Append($ch) }
            }
            $value = $sb.ToString()
            if (-not [string]::IsNullOrEmpty($value)) { return $value }
        }
    }

    $detected = Get-FmBackendDetected
    if (-not [string]::IsNullOrEmpty($detected.Backend)) {
        if ([string]::Equals($detected.Backend, 'herdr', $script:FmBackendOrdinal)) {
            Write-FmErr 'NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend. Set config/backend or pass --backend tmux to opt out.'
        }
        if ([string]::Equals($detected.Backend, 'cmux', $script:FmBackendOrdinal)) {
            $marker = switch -CaseSensitive ($detected.Signal) {
                'bundle-id' { "FALLBACK signal __CFBundleIdentifier=$($script:FmBackendCmuxBundleId); CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" }
                'ancestry' { "FALLBACK signal process-ancestry reaching the running cmux app; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" }
                default { 'CMUX_WORKSPACE_ID' }
            }
            Write-FmErr "NOTICE: auto-detected cmux runtime ($marker) - spawning into the EXPERIMENTAL cmux backend. Set config/backend or pass --backend tmux to opt out."
        }
        return $detected.Backend
    }
    return 'tmux'
}

# --- validation ---------------------------------------------------------------

<#
.SYNOPSIS
Refuse an unknown backend LOUDLY. Silent on success.
.DESCRIPTION
Twin of fm_backend_validate, including the exact refusal text every suite in the
tree greps for.
#>
function Test-FmBackendValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    if (-not (Test-FmBackendKnown $Name)) {
        Write-FmErr "error: unknown backend '$Name' (known: $($script:FmBackendKnown -join ' '))"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Refuse a backend that cannot spawn a task, after the known-backend check.
.DESCRIPTION
Twin of fm_backend_validate_spawn. Every implemented lifecycle backend is
spawn-capable today, so the second refusal is a contract for a future read-only
adapter rather than a live path.
#>
function Test-FmBackendSpawnValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    if (-not (Test-FmBackendValid $Name)) { return $false }
    if (Test-FmBackendListContains -List ($script:FmBackendSpawn -join ' ') -Name $Name) { return $true }
    Write-FmErr "error: backend '$Name' does not support task spawning yet (spawn-supported: $($script:FmBackendSpawn -join ' '))"
    return $false
}

<#
.SYNOPSIS
The backend-SPECIFIC CLI tools a firstmate home on this backend requires.
.DESCRIPTION
Twin of fm_backend_required_tools, and the single owner of the per-backend
dependency delta beyond firstmate's universal toolchain, so bootstrap follows
the RESOLVED backend instead of demanding an inactive backend's tools. Each set
is the session-provider CLI itself; jq for the JSON-emitting experimental
adapters whose spawn and liveness paths parse the backend's JSON; and the
treehouse worktree provider for every session-provider-only backend. Orca owns
its own task worktree and terminal, so it drops both.

Returns a single space-separated line for a known backend, $null for an unknown
one.
#>
function Get-FmBackendRequiredTool {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    switch -CaseSensitive ($Name) {
        'tmux' { return 'tmux treehouse' }
        'herdr' { return 'herdr jq treehouse' }
        'zellij' { return 'zellij jq treehouse' }
        'cmux' { return 'cmux jq treehouse' }
        'orca' { return 'orca' }
        default { return $null }
    }
}

<#
.SYNOPSIS
Is one of this backend's required tools actually available?
.DESCRIPTION
Twin of fm_backend_required_tool_available. A tool that is not in the backend's
required set answers $false rather than being probed, so bootstrap cannot report
an inactive backend's dependency as satisfied.

cmux's own CLI is the one special case: it is resolved through the adapter's
binary lookup rather than PATH, because cmux ships its CLI inside the app
bundle. Until bin/backends/cmux.psm1 exists that arm answers $false, which is
the correct fail-closed reading of "this home cannot use cmux from PowerShell
yet".
#>
function Test-FmBackendRequiredTool {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Tool = ''
    )

    $required = Get-FmBackendRequiredTool $Name
    if ($null -eq $required) { return $false }
    if (-not (Test-FmBackendListContains -List $required -Name $Tool)) { return $false }
    if ([string]::Equals($Name, 'cmux', $script:FmBackendOrdinal) -and
        [string]::Equals($Tool, 'cmux', $script:FmBackendOrdinal)) {
        if (-not (Import-FmBackendAdapter -Name 'cmux' -Quiet)) { return $false }
        return [bool](Get-FmBackendCmuxBinary)
    }
    return Test-FmCommand $Tool
}

# --- meta records -------------------------------------------------------------

<#
.SYNOPSIS
The backend recorded in a meta file, defaulting to tmux when absent.
.DESCRIPTION
Twin of fm_backend_of_meta, and the P1 compatibility contract: a task meta with
no `backend=` line IS a tmux task, in both language trees, for ever.
#>
function Get-FmBackendOfMeta {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MetaPath = '')

    $value = Get-FmMetaValue $MetaPath 'backend'
    if ([string]::IsNullOrEmpty($value)) { return 'tmux' }
    return $value
}

<#
.SYNOPSIS
The recorded endpoint target for a task, or '' when there is none.
.DESCRIPTION
Twin of fm_backend_target_of_meta. Orca is the exception in the fleet: it owns
both the worktree and the terminal, so its endpoint is `terminal=` and `window=`
holds only the fm-<id> label.
#>
function Get-FmBackendTargetOfMeta {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MetaPath = '')

    if ([string]::Equals((Get-FmBackendOfMeta $MetaPath), 'orca', $script:FmBackendOrdinal)) {
        $terminal = Get-FmMetaValue $MetaPath 'terminal'
        if (-not [string]::IsNullOrEmpty($terminal)) { return $terminal }
    }
    return (Get-FmMetaValue $MetaPath 'window')
}

<#
.SYNOPSIS
A meta value that appears EXACTLY once and is non-empty, or $null.
.DESCRIPTION
Twin of fm_backend_meta_exact_value, and deliberately stricter than
Get-FmMetaValue's last-wins read: this is the endpoint-validation reader, where
an AMBIGUOUS record (two `window=` lines, say, one of them belonging to a
superseded incarnation) must refuse rather than pick a winner.
#>
function Get-FmBackendMetaExactValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MetaPath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = ''
    )

    $prefix = "$Key="
    $found = $null
    $count = 0
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        if ($line.StartsWith($prefix, $script:FmBackendOrdinal)) {
            $count++
            $found = $line.Substring($prefix.Length)
        }
    }
    if ($count -ne 1) { return $null }
    if ([string]::IsNullOrEmpty($found)) { return $null }
    return $found
}

# `grep -c "^$key="`, for the arms that branch on 0 / 1 / many rather than on a
# value.
function Get-FmBackendMetaKeyCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MetaPath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = ''
    )
    $prefix = "$Key="
    $count = 0
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        if ($line.StartsWith($prefix, $script:FmBackendOrdinal)) { $count++ }
    }
    return $count
}

<#
.SYNOPSIS
Is this endpoint atom made only of characters an endpoint identifier may hold?
.DESCRIPTION
Twin of fm_backend_endpoint_atom_valid: `A-Za-z0-9._@%+-` and nothing else, with
the empty string rejected. This is what keeps a crafted or corrupted metadata
field from reaching a backend CLI as an argument.
#>
function Test-FmBackendEndpointAtom {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value = '')

    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return ($Value -match '^[A-Za-z0-9._@%+\-]+$')
}

<#
.SYNOPSIS
Validate a task cleanup record entirely from its durable metadata.
.DESCRIPTION
Twin of fm_backend_validate_task_endpoint, run BEFORE any runtime command or
cleanup mutation. The validation binds the exact task id, selected backend,
target, project and worktree together, so a record that has been partly
overwritten, or that belongs to a different task, refuses instead of pointing a
kill at someone else's endpoint.

New non-tmux records carry endpoint_task_id because their opaque runtime ids do
not encode the task label. Legacy tmux records remain valid only when the window
name itself is exactly fm-<task-id>.

Returns @{ Ok; Backend; Target } - the twin of the bash pair
FM_BACKEND_VALIDATED_BACKEND / FM_BACKEND_VALIDATED_TARGET, which exist only
because a bash function cannot return three values. On failure Ok is $false, one
refusal has been written to stderr, and Backend/Target are empty.
#>
function Get-FmBackendValidatedEndpoint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MetaPath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TaskId = ''
    )

    $deny = @{ Ok = $false; Backend = ''; Target = '' }
    $native = ConvertTo-FmNativePath $MetaPath

    if (-not [System.IO.File]::Exists($native) -or (Test-FmSymlink $native)) {
        Write-FmErr "REFUSED: task $TaskId has no regular endpoint metadata at $MetaPath; preserving task state."
        return $deny
    }
    if ([string]::IsNullOrEmpty($TaskId) -or ($TaskId -notmatch '^[A-Za-z0-9._\-]+$')) {
        Write-FmErr 'REFUSED: task endpoint identity has an invalid task id; preserving task state.'
        return $deny
    }

    $window = Get-FmBackendMetaExactValue $MetaPath 'window'
    if ($null -eq $window) {
        Write-FmErr "REFUSED: task $TaskId has a missing, empty, or ambiguous window endpoint; preserving task state."
        return $deny
    }
    $worktree = Get-FmBackendMetaExactValue $MetaPath 'worktree'
    if ($null -eq $worktree) {
        Write-FmErr "REFUSED: task $TaskId has a missing, empty, or ambiguous worktree identity; preserving task state."
        return $deny
    }
    $project = Get-FmBackendMetaExactValue $MetaPath 'project'
    if ($null -eq $project) {
        Write-FmErr "REFUSED: task $TaskId has a missing, empty, or ambiguous project identity; preserving task state."
        return $deny
    }
    $joined = "$worktree$project$window"
    if ($joined.Contains("`n") -or $joined.Contains("`r") -or $joined.Contains("`t")) {
        Write-FmErr "REFUSED: task $TaskId has malformed endpoint metadata; preserving task state."
        return $deny
    }

    $backend = ''
    switch -CaseSensitive (Get-FmBackendMetaKeyCount $MetaPath 'backend') {
        0 { $backend = 'tmux' }
        1 {
            $backend = Get-FmBackendMetaExactValue $MetaPath 'backend'
            if ($null -eq $backend) { $backend = '' }
        }
        default { $backend = '' }
    }
    if ([string]::IsNullOrEmpty($backend) -or -not (Test-FmBackendKnown $backend)) {
        Write-FmErr "REFUSED: task $TaskId has a missing, ambiguous, or unknown backend identity; preserving task state."
        return $deny
    }

    $binding = ''
    switch -CaseSensitive (Get-FmBackendMetaKeyCount $MetaPath 'endpoint_task_id') {
        0 { $binding = '' }
        1 {
            $binding = Get-FmBackendMetaExactValue $MetaPath 'endpoint_task_id'
            if ($null -eq $binding) {
                Write-FmErr "REFUSED: task $TaskId has an empty endpoint task binding; preserving task state."
                return $deny
            }
        }
        default {
            Write-FmErr "REFUSED: task $TaskId has an ambiguous endpoint task binding; preserving task state."
            return $deny
        }
    }
    if (-not [string]::IsNullOrEmpty($binding) -and -not [string]::Equals($binding, $TaskId, $script:FmBackendOrdinal)) {
        Write-FmErr "REFUSED: endpoint metadata belongs to task $binding, not $TaskId; preserving task state."
        return $deny
    }

    $target = $window
    switch -CaseSensitive ($backend) {
        'tmux' {
            $colon = $window.IndexOf(':')
            $session = if ($colon -ge 0) { $window.Substring(0, $colon) } else { '' }
            $pane = if ($colon -ge 0) { $window.Substring($colon + 1) } else { $window }
            if ($colon -lt 0 -or -not [string]::Equals($pane, "fm-$TaskId", $script:FmBackendOrdinal) -or
                [string]::IsNullOrEmpty($session)) {
                Write-FmErr "REFUSED: tmux endpoint '$window' is malformed or does not belong to task $TaskId; preserving task state."
                return $deny
            }
        }
        'herdr' {
            if (-not [string]::Equals($binding, $TaskId, $script:FmBackendOrdinal)) {
                Write-FmErr "REFUSED: legacy Herdr endpoint metadata for task $TaskId lacks an exact task binding; preserving task state."
                return $deny
            }
            $session = Get-FmBackendMetaExactValue $MetaPath 'herdr_session'
            $workspace = Get-FmBackendMetaExactValue $MetaPath 'herdr_workspace_id'
            $tab = Get-FmBackendMetaExactValue $MetaPath 'herdr_tab_id'
            $pane = Get-FmBackendMetaExactValue $MetaPath 'herdr_pane_id'
            if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($workspace) -or
                [string]::IsNullOrEmpty($tab) -or [string]::IsNullOrEmpty($pane) -or
                -not [string]::Equals($window, "${session}:${pane}", $script:FmBackendOrdinal) -or
                -not (Test-FmBackendEndpointAtom $session) -or
                -not (Test-FmBackendEndpointAtom $workspace) -or
                -not (Test-FmBackendEndpointAtom ($tab.Replace(':', '_'))) -or
                -not (Test-FmBackendEndpointAtom ($pane.Replace(':', '_')))) {
                Write-FmErr "REFUSED: Herdr endpoint metadata for task $TaskId is malformed or inconsistent; preserving task state."
                return $deny
            }
        }
        'zellij' {
            if (-not [string]::Equals($binding, $TaskId, $script:FmBackendOrdinal)) {
                Write-FmErr "REFUSED: legacy Zellij endpoint metadata for task $TaskId lacks an exact task binding; preserving task state."
                return $deny
            }
            $session = Get-FmBackendMetaExactValue $MetaPath 'zellij_session'
            $tab = Get-FmBackendMetaExactValue $MetaPath 'zellij_tab_id'
            $pane = Get-FmBackendMetaExactValue $MetaPath 'zellij_pane_id'
            # `case "$tab:$pane" in *[!0-9:]*) tab= ;;` - any non-digit in
            # either id blanks the tab, which then fails the emptiness check.
            if ("$tab`:$pane" -match '[^0-9:]') { $tab = '' }
            if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($tab) -or
                [string]::IsNullOrEmpty($pane) -or
                -not [string]::Equals($window, "${session}:${pane}", $script:FmBackendOrdinal) -or
                -not (Test-FmBackendEndpointAtom $session)) {
                Write-FmErr "REFUSED: Zellij endpoint metadata for task $TaskId is malformed or inconsistent; preserving task state."
                return $deny
            }
        }
        'orca' {
            if (-not [string]::Equals($binding, $TaskId, $script:FmBackendOrdinal)) {
                Write-FmErr "REFUSED: legacy Orca endpoint metadata for task $TaskId lacks an exact task binding; preserving task state."
                return $deny
            }
            $terminal = Get-FmBackendMetaExactValue $MetaPath 'terminal'
            $worktreeId = Get-FmBackendMetaExactValue $MetaPath 'orca_worktree_id'
            if ([string]::IsNullOrEmpty($terminal)) {
                Write-FmErr "REFUSED: missing terminal in $MetaPath; cannot close Orca endpoint; preserving task state."
                return $deny
            }
            if ([string]::IsNullOrEmpty($worktreeId)) {
                Write-FmErr "REFUSED: missing orca_worktree_id in $MetaPath; cannot remove Orca worktree; preserving task state."
                return $deny
            }
            if (-not [string]::Equals($window, "fm-$TaskId", $script:FmBackendOrdinal) -or
                -not (Test-FmBackendEndpointAtom $terminal) -or
                -not (Test-FmBackendEndpointAtom $worktreeId)) {
                Write-FmErr "REFUSED: Orca endpoint metadata for task $TaskId is malformed or inconsistent; preserving task state."
                return $deny
            }
            $target = $terminal
        }
        'cmux' {
            if (-not [string]::Equals($binding, $TaskId, $script:FmBackendOrdinal)) {
                Write-FmErr "REFUSED: legacy cmux endpoint metadata for task $TaskId lacks an exact task binding; preserving task state."
                return $deny
            }
            $workspace = Get-FmBackendMetaExactValue $MetaPath 'cmux_workspace_id'
            $surface = Get-FmBackendMetaExactValue $MetaPath 'cmux_surface_id'
            if ([string]::IsNullOrEmpty($workspace) -or [string]::IsNullOrEmpty($surface) -or
                -not [string]::Equals($window, "${workspace}:${surface}", $script:FmBackendOrdinal) -or
                -not (Test-FmBackendEndpointAtom $workspace) -or
                -not (Test-FmBackendEndpointAtom $surface)) {
                Write-FmErr "REFUSED: cmux endpoint metadata for task $TaskId is malformed or inconsistent; preserving task state."
                return $deny
            }
        }
    }

    return @{ Ok = $true; Backend = $backend; Target = $target }
}

# --- selector resolution ------------------------------------------------------

<#
.SYNOPSIS
The meta file in <state-dir> whose window= or terminal= is exactly <target>.
.DESCRIPTION
Twin of fm_backend_meta_for_window. The listing is sorted ORDINALLY before the
scan because a bash glob is sorted and .NET enumeration order is not, and two
metas naming the same window must not resolve differently in the two worlds
(divergence 4).
#>
function Get-FmBackendMetaForWindow {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    $dir = ConvertTo-FmNativePath $StateDir
    if (-not [System.IO.Directory]::Exists($dir)) { return $null }
    $metas = @([System.IO.Directory]::EnumerateFiles($dir, '*.meta'))
    # Ordinal, because .NET enumeration order is not guaranteed and a
    # culture-aware sort can reorder punctuated task ids (divergence 4).
    [Array]::Sort($metas, [System.StringComparer]::Ordinal)
    foreach ($meta in $metas) {
        $window = Get-FmMetaValue $meta 'window'
        $terminal = Get-FmMetaValue $meta 'terminal'
        $hit = ((-not [string]::IsNullOrEmpty($window)) -and [string]::Equals($window, $Target, $script:FmBackendOrdinal)) -or
               ((-not [string]::IsNullOrEmpty($terminal)) -and [string]::Equals($terminal, $Target, $script:FmBackendOrdinal))
        if ($hit) { return $meta }
    }
    return $null
}

<#
.SYNOPSIS
The task id a raw selector names, or $null.
.DESCRIPTION
Twin of fm_backend_task_id_for_selector: an EXACT `<id>.meta` first, then the
legacy `fm-<id>` label stripped back to `<id>.meta`. A selector containing ':'
is an explicit backend target and is never a task id.

The exact-first ordering matters for a task whose own id starts with "fm-":
stripping first would resolve it to a different task's record.
#>
function Get-FmBackendTaskIdForSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    if ($null -eq $Raw) { $Raw = '' }
    if ($Raw.Contains(':')) { return $null }
    $dir = ConvertTo-FmNativePath $StateDir
    if ([System.IO.File]::Exists((Join-Path $dir "$Raw.meta"))) { return $Raw }
    if ($Raw.StartsWith('fm-', $script:FmBackendOrdinal)) {
        $id = $Raw.Substring(3)
        if (-not [System.IO.File]::Exists((Join-Path $dir "$id.meta"))) { return $null }
        return $id
    }
    return $null
}

<#
.SYNOPSIS
The meta path a raw selector resolves to, or $null.
.DESCRIPTION
Twin of fm_backend_meta_for_selector. The path is COMPOSED, exactly as the bash
`printf '%s/%s.meta'` does, and is not re-checked for existence -
Get-FmBackendTaskIdForSelector only returns an id whose meta it already found.
#>
function Get-FmBackendMetaForSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    $id = Get-FmBackendTaskIdForSelector -Raw $Raw -StateDir $StateDir
    if ($null -eq $id) { return $null }
    return (Join-Path (ConvertTo-FmNativePath $StateDir) "$id.meta")
}

<#
.SYNOPSIS
The backend a selector belongs to, defaulting to tmux.
.DESCRIPTION
Twin of fm_backend_of_selector: the selector's own metadata first, then a
metadata record matching the RESOLVED target, then the tmux compatibility
default. An explicit target outside this home has no record and stays tmux,
which is what the pre-backend behavior was.
#>
function Get-FmBackendOfSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Resolved = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    $meta = Get-FmBackendMetaForSelector -Raw $Raw -StateDir $StateDir
    if (-not [string]::IsNullOrEmpty($meta)) { return (Get-FmBackendOfMeta $meta) }
    if (-not [string]::IsNullOrEmpty($Resolved)) {
        $meta = Get-FmBackendMetaForWindow -Target $Resolved -StateDir $StateDir
        if (-not [string]::IsNullOrEmpty($meta)) { return (Get-FmBackendOfMeta $meta) }
    }
    return 'tmux'
}

<#
.SYNOPSIS
The fm-<id> endpoint label a task selector was spawned with, or ''.
.DESCRIPTION
Twin of fm_backend_expected_label_of_selector, which always succeeds: a selector
that names no task simply has no label, and callers pass the empty string
through to a backend that then skips label verification.
#>
function Get-FmBackendExpectedLabelOfSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    $id = Get-FmBackendTaskIdForSelector -Raw $Raw -StateDir $StateDir
    if ([string]::IsNullOrEmpty($id)) { return '' }
    return "fm-$id"
}

# --- adapter loading ----------------------------------------------------------

<#
.SYNOPSIS
Load the named backend's adapter module, once per process.
.DESCRIPTION
Twin of fm_backend_source. See ADAPTER LOADING in the file header for the two
imports and why both are needed, and for what an unconverted adapter does.

-Quiet suppresses the missing-adapter diagnostic for the one caller that probes
rather than dispatches (Test-FmBackendRequiredTool, whose bash twin redirects
that path to /dev/null).
#>
function Import-FmBackendAdapter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '',
        [switch]$Quiet
    )

    if (-not (Test-FmBackendValid $Name)) { return $false }
    if ($script:FmBackendAdapterLoaded.ContainsKey($Name)) { return $true }

    $path = Join-Path $PSScriptRoot 'backends' "$Name.psm1"
    if (-not [System.IO.File]::Exists($path)) {
        if (-not $Quiet) {
            Write-FmErr "error: backend '$Name' has no PowerShell adapter yet ($path); the bash adapter cannot be imported into PowerShell"
        }
        return $false
    }

    try {
        Import-Module $path
        Import-Module $path -Global
    } catch {
        if (-not $Quiet) {
            Write-FmErr "error: backend '$Name' adapter failed to load: $($_.Exception.Message)"
        }
        return $false
    }
    $script:FmBackendAdapterLoaded[$Name] = $true
    return $true
}

<#
.SYNOPSIS
Resolve a raw fm-send/fm-peek style selector to a live backend target.
.DESCRIPTION
Twin of fm_backend_resolve_selector. Four forms, in order:

  target with ":"  used as-is - the escape hatch for a window or pane outside
                   this firstmate home. Backend-independent, a literal string.
  exact task id    routed through <state-dir>/<id>.meta's recorded target
                   (window=, or terminal= for Orca). NOT re-verified against a
                   live backend inventory, matching today's behavior.
  "fm-<id>"        legacy task window label, routed through <state-dir>/<id>.meta
                   when no exact fm-<id>.meta exists.
  anything else    first matched against recorded window=/terminal= metadata,
                   then treated as an ad hoc bare window name and resolved by
                   searching the live tmux inventory.

An fm-* selector with no metadata is REFUSED rather than falling through to the
live search: a task label that has lost its record must not silently bind to
whatever window happens to carry that name. Returns $null after writing the
refusal.
#>
function Resolve-FmBackendSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = ''
    )

    if ($null -eq $Raw) { $Raw = '' }
    if ($Raw.Contains(':')) { return $Raw }

    $meta = Get-FmBackendMetaForSelector -Raw $Raw -StateDir $StateDir
    if (-not [string]::IsNullOrEmpty($meta)) {
        $window = Get-FmBackendTargetOfMeta $meta
        if ([string]::IsNullOrEmpty($window)) {
            Write-FmErr "error: no backend target recorded in $meta"
            return $null
        }
        return $window
    }

    if ($Raw.StartsWith('fm-', $script:FmBackendOrdinal)) {
        Write-FmErr "error: no metadata for $Raw in $StateDir; pass session:window to target a window outside this firstmate home"
        return $null
    }

    $meta = Get-FmBackendMetaForWindow -Target $Raw -StateDir $StateDir
    if (-not [string]::IsNullOrEmpty($meta)) {
        $window = Get-FmBackendTargetOfMeta $meta
        if ([string]::IsNullOrEmpty($window)) {
            Write-FmErr "error: no backend target recorded in $meta"
            return $null
        }
        return $window
    }

    if (-not (Import-FmBackendAdapter -Name 'tmux')) { return $null }
    return Resolve-FmBackendTmuxBareSelector $Raw
}

# --- generic per-op dispatch --------------------------------------------------
#
# Thin dispatch wrappers so a caller names an operation and a backend rather than
# hand-writing a per-backend switch at every call site. Each verified backend
# adds its own arm here without changing call sites. The `default` arms are
# unreachable while Test-FmBackendValid gates every entry, and are kept for the
# same reason the bash twin keeps them: a new name added to the known set
# without an implementation must be loud, not silent.

<#
.SYNOPSIS
Bounded plain-text session capture.
.DESCRIPTION
Twin of fm_backend_capture. Returns the adapter's RAW capture text - see the
trailing-newline note in bin/backends/tmux.psm1 - or $null when the backend
could not be loaded or the capture failed.
#>
function Get-FmBackendCapture {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return $null }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Get-FmBackendTmuxCapture $Target $Lines $ExpectedLabel }
        'herdr' { return Get-FmBackendHerdrCapture $Target $Lines $ExpectedLabel }
        'zellij' { return Get-FmBackendZellijCapture $Target $Lines $ExpectedLabel }
        'orca' { return Get-FmBackendOrcaCapture $Target $Lines $ExpectedLabel }
        'cmux' { return Get-FmBackendCmuxCapture $Target $Lines $ExpectedLabel }
        default {
            Write-FmErr "error: no capture implementation for backend '$Backend'"
            return $null
        }
    }
}

<#
.SYNOPSIS
Send one backend-supported named special key.
.DESCRIPTION
Twin of fm_backend_send_key.
#>
function Send-FmBackendKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Send-FmBackendTmuxKey $Target $Key $ExpectedLabel }
        'herdr' { return Send-FmBackendHerdrKey $Target $Key $ExpectedLabel }
        'zellij' { return Send-FmBackendZellijKey $Target $Key $ExpectedLabel }
        'orca' { return Send-FmBackendOrcaKey $Target $Key $ExpectedLabel }
        'cmux' { return Send-FmBackendCmuxKey $Target $Key $ExpectedLabel }
        default {
            Write-FmErr "error: no send-key implementation for backend '$Backend'"
            return $false
        }
    }
}

<#
.SYNOPSIS
Type text once, then submit and verify, retrying only the submission.
.DESCRIPTION
Twin of fm_backend_send_text_submit. Echoes the backend's proof-carrying
verdict; callers require exact `empty` for confirmed delivery, and NEVER retype
on retry - a re-typed instruction would be delivered twice to a live agent.
#>
function Send-FmBackendTextSubmit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0',
        [Parameter(Position = 5)][AllowEmptyString()][AllowNull()][string]$Settle = '0',
        [Parameter(Position = 6)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return $null }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Send-FmBackendTmuxTextSubmit $Target $Text $Retries $EnterSleep $Settle $ExpectedLabel }
        'herdr' { return Send-FmBackendHerdrTextSubmit $Target $Text $Retries $EnterSleep $Settle $ExpectedLabel }
        'zellij' { return Send-FmBackendZellijTextSubmit $Target $Text $Retries $EnterSleep $Settle $ExpectedLabel }
        'orca' { return Send-FmBackendOrcaTextSubmit $Target $Text $Retries $EnterSleep $Settle $ExpectedLabel }
        'cmux' { return Send-FmBackendCmuxTextSubmit $Target $Text $Retries $EnterSleep $Settle $ExpectedLabel }
        default {
            Write-FmErr "error: no send-text implementation for backend '$Backend'"
            return $null
        }
    }
}

<#
.SYNOPSIS
Remove the task's session endpoint, best-effort.
.DESCRIPTION
Twin of fm_backend_kill. A nonexistent or already-gone target is NOT an error -
callers already swallowed failures here exactly as the inline
`tmux kill-window ... || true` did - but an EMPTY target is refused before any
adapter is loaded, because a backend CLI can read an empty target as "the
current window" and kill whatever the captain is looking at.
#>
function Remove-FmBackendTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal dispatcher whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )

    if ([string]::IsNullOrEmpty($Target)) {
        Write-FmErr 'error: refusing empty backend kill target'
        return $false
    }
    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Remove-FmBackendTmuxTarget $Target }
        'herdr' { return Remove-FmBackendHerdrTarget $Target }
        'zellij' { return Remove-FmBackendZellijTarget $Target }
        'orca' { return Remove-FmBackendOrcaTarget $Target }
        'cmux' { return Remove-FmBackendCmuxTarget $Target }
        default {
            Write-FmErr "error: no kill implementation for backend '$Backend'"
            return $false
        }
    }
}

<#
.SYNOPSIS
Remove a backend-owned task worktree.
.DESCRIPTION
Twin of fm_backend_remove_worktree. Only Orca owns task worktrees; every other
backend is session-provider-only and refuses loudly rather than guessing at a
worktree it does not manage.
#>
function Remove-FmBackendWorktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal dispatcher whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WorktreeId = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'orca' { return Remove-FmBackendOrcaWorktree $WorktreeId }
        default {
            Write-FmErr "error: backend '$Backend' does not own task worktrees"
            return $false
        }
    }
}

<#
.SYNOPSIS
The filesystem path of a backend-owned task worktree.
.DESCRIPTION
Twin of fm_backend_worktree_path. Orca-only, for the same reason as
Remove-FmBackendWorktree.
#>
function Get-FmBackendWorktreePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WorktreeId = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return $null }
    switch -CaseSensitive ($Backend) {
        'orca' { return Get-FmBackendOrcaWorktreePath $WorktreeId }
        default {
            Write-FmErr "error: backend '$Backend' does not own task worktrees"
            return $null
        }
    }
}

<#
.SYNOPSIS
Semantic busy/idle/unknown for backends with a native agent-state primitive.
.DESCRIPTION
Twin of fm_backend_busy_state. Backends with no such primitive - tmux included -
report `unknown`, and CALLERS own the fallback policy: fm-watch uses unknown as
the cue for harness-scoped pane-tail detection, while fm-crew-state also
corroborates a native idle verdict with the recorded harness's signature before
treating a no-run crew as not busy. A backend that cannot be loaded is `unknown`
too, never a guess.
#>
function Get-FmBackendBusyState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return 'unknown' }
    switch -CaseSensitive ($Backend) {
        'herdr' { return Get-FmBackendHerdrBusyState $Target }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
Classify the composer/input row of a target across backends.
.DESCRIPTION
Twin of fm_backend_composer_state. Exposed so a caller other than the send path -
the away-mode daemon's supervisor-pane pending-input guard - can ask the same
question without duplicating per-backend composer reading.

zellij's submit path uses an internal content-diff approach with no separately
named classifier, so it reports `unknown` here and callers fall back to their own
policy, exactly as an unknown busy state already does.
#>
function Get-FmBackendComposerState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return 'unknown' }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Get-FmTmuxComposerState $Target }
        'herdr' { return Get-FmBackendHerdrComposerState $Target }
        'orca' { return Get-FmBackendOrcaComposerState $Target }
        'cmux' { return Get-FmBackendCmuxComposerState $Target }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
Cheap, READ-ONLY existence check for a recorded endpoint.
.DESCRIPTION
Twin of fm_backend_target_exists. NEVER starts a server or session: the tmux arm
reads the pane directly rather than going through anything that could create
one, and the herdr arm deliberately queries the pane instead of the adapter's
target-ready helper, which auto-starts the herdr server as a side effect - fine
for an operation about to USE the pane, wrong for a passive liveness probe.

A gone window, an unqueryable pane, a missing zellij pane or an unreadable Orca
terminal all simply fail, which IS "does not exist" for this purpose. Callers
that need the RICHER recovery verdict - and in particular the difference between
"authoritatively absent" and "could not be read" - use Get-FmBackendAgentState
instead; this one deliberately collapses both to $false and must never be used
to license a teardown or a respawn.
#>
function Test-FmBackendTargetExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing s belongs to the verb Exists, not to a plural noun. This exact name is also a published contract: bin/fm-busy-lib.psm1 probes for Test-FmBackendTargetExists by name through Get-Command, so renaming it would silently disable the busy-state endpoint probe rather than fail loudly.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if ($null -eq $Target) { $Target = '' }
    switch -CaseSensitive ($Backend) {
        'tmux' {
            # No adapter load: the bash twin reads the pane directly here, and
            # keeping that means a liveness digest over a dozen tasks does not
            # import an adapter it will not otherwise use.
            return [bool](Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{pane_id}')).Ok
        }
        'herdr' {
            if (-not (Import-FmBackendAdapter 'herdr')) { return $false }
            $colon = $Target.IndexOf(':')
            if ($colon -lt 0) { return $false }
            $session = $Target.Substring(0, $colon)
            $pane = $Target.Substring($colon + 1)
            if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($pane)) { return $false }
            # The session-scoped CLI helper, not a bare HERDR_SESSION call:
            # verified empirically (docs/herdr-backend.md "Session targeting")
            # that the bare env var is NOT reliably honored once another herdr
            # server is bound on the machine - it silently queries whatever
            # server IS running.
            return [bool](Invoke-FmBackendHerdrCli $session @('pane', 'get', $pane)).Ok
        }
        'zellij' {
            if (-not (Import-FmBackendAdapter 'zellij')) { return $false }
            return [bool](Test-FmBackendZellijTargetReady $Target $ExpectedLabel)
        }
        'orca' {
            if (-not (Import-FmBackendAdapter 'orca')) { return $false }
            return ($null -ne (Get-FmBackendOrcaCapture $Target '1'))
        }
        'cmux' {
            if (-not (Import-FmBackendAdapter 'cmux')) { return $false }
            return [bool](Test-FmBackendCmuxTargetReady $Target $ExpectedLabel)
        }
        default { return $false }
    }
}

<#
.SYNOPSIS
The single recovery-grade agent/endpoint state contract.
.DESCRIPTION
Twin of fm_backend_agent_state, and deliberately richer than
Test-FmBackendTargetExists's cheap pane-presence read. Returns exactly one of:

  alive       a verified harness agent is running.
  dead        the endpoint exists but confidently has no agent.
  missing     the recorded endpoint is authoritatively absent.
  ambiguous   the endpoint exists but its process cannot be attributed.
  unreadable  a target or inventory read failed or contradicted itself.
  unverified  this backend has no recovery classifier.

ONLY `dead` AND `missing` LICENSE RECOVERY. Everything else must leave the task
alone, because relaunching against an endpoint that merely could not be read
double-spawns a crew that is still working. zellij stays unverified because its
ghost-tab and agent-process recovery path has not been empirically validated;
orca and cmux do not support secondmate spawns.
#>
function Get-FmBackendAgentState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )

    if (-not (Import-FmBackendAdapter $Backend)) { return 'unverified' }
    switch -CaseSensitive ($Backend) {
        'tmux' { return Get-FmBackendTmuxAgentState $Target }
        'herdr' { return Get-FmBackendHerdrAgentState $Target }
        default { return 'unverified' }
    }
}

<#
.SYNOPSIS
Backward-compatible three-state view for existing callers.
.DESCRIPTION
Twin of fm_backend_agent_alive. An authoritatively missing endpoint is
confidently not a live agent, while every ambiguous, unreadable or unverified
result stays `unknown` - never `dead`.
#>
function Get-FmBackendAgentAlive {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )

    switch -CaseSensitive (Get-FmBackendAgentState $Backend $Target) {
        'alive' { return 'alive' }
        'dead' { return 'dead' }
        'missing' { return 'dead' }
        default { return 'unknown' }
    }
}

# --- native event push (backend-extensible) ----------------------------------
#
# The watcher's event-wait splice is backend-agnostic: it asks
# Test-FmBackendHasPush whether a window's backend can push semantic state
# changes, and for those backends replaces its blind poll sleep with a bounded
# wait on Wait-FmBackendTransition. Every push-capable backend reuses the shared
# normalized-transition shape and policy table (bin/fm-transition-lib); today
# only herdr implements the surface. A backend with no native push reports
# has-push false and returns Code 2 below, so the watcher falls back to its poll
# loop - the permanent backstop that keeps supervision working when the event
# path is unusable.

<#
.SYNOPSIS
Does this backend expose a native transition push stream?
.DESCRIPTION
Twin of fm_backend_has_push.
#>
function Test-FmBackendHasPush {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '')
    return [string]::Equals($Backend, 'herdr', $script:FmBackendOrdinal)
}

<#
.SYNOPSIS
Is this backend's push path usable for this session right now?
.DESCRIPTION
Twin of fm_backend_events_capable - a version/schema/reader gate. Non-push
backends are never capable. The watcher memoizes this per session so the
potentially heavy capability probe is not repeated every poll.
#>
function Test-FmBackendEventsCapable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Session = ''
    )

    if (-not (Test-FmBackendHasPush $Backend)) { return $false }
    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'herdr' { return [bool](Test-FmBackendHerdrEventsCapable $Session) }
        default { return $false }
    }
}

<#
.SYNOPSIS
Bounded wait for a fresh actionable transition on one of several panes.
.DESCRIPTION
Twin of fm_backend_wait_transition. Returns @{ Code; Record } where Code is the
bash exit-status trichotomy every caller branches on:

  0  a fresh actionable (blocked) edge; Record holds the normalized transition
  1  a clean timeout - the caller has effectively already slept its budget
  2  the event path is unusable, so the caller sleeps the budget itself

Non-push backends always return 2, which is what keeps the poll-loop backstop
reachable rather than silently dropping the watcher's sleep.
#>
function Wait-FmBackendTransition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$TimeoutSeconds = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 4)][AllowNull()][AllowEmptyCollection()][string[]]$PaneWindow = @()
    )

    if (-not (Test-FmBackendHasPush $Backend)) { return @{ Code = 2; Record = '' } }
    if (-not (Import-FmBackendAdapter $Backend)) { return @{ Code = 2; Record = '' } }
    switch -CaseSensitive ($Backend) {
        'herdr' { return Wait-FmBackendHerdrTransition $Session $TimeoutSeconds $StateDir @($PaneWindow) }
        default { return @{ Code = 2; Record = '' } }
    }
}

<#
.SYNOPSIS
Commit a normalized transition record as the backend's new known state.
.DESCRIPTION
Twin of fm_backend_commit_transition.
#>
function Save-FmBackendTransition {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal dispatcher whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall the watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Record = ''
    )

    if (-not (Test-FmBackendHasPush $Backend)) { return $false }
    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'herdr' { return [bool](Save-FmBackendHerdrTransition $StateDir $Session $Record) }
        default { return $false }
    }
}

<#
.SYNOPSIS
Clear a window's recorded transition state.
.DESCRIPTION
Twin of fm_backend_clear_transition. A non-push backend has nothing to clear and
answers $true - the bash twin returns 0 there, so a caller must not treat the
absence of push as a failed clear and retry for ever.
#>
function Clear-FmBackendTransition {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal dispatcher whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall the watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Window = ''
    )

    if (-not (Test-FmBackendHasPush $Backend)) { return $true }
    if (-not (Import-FmBackendAdapter $Backend)) { return $false }
    switch -CaseSensitive ($Backend) {
        'herdr' { return [bool](Clear-FmBackendHerdrTransition $StateDir $Window) }
        default { return $true }
    }
}

Export-ModuleMember -Function @(
    'Get-FmBackendKnownName', 'Get-FmBackendSpawnName',
    'Test-FmBackendListContains', 'Test-FmBackendKnown',
    'Get-FmBackendDetected', 'Get-FmBackendCmuxFallbackSignal',
    'Get-FmBackendCmuxAppProcessId', 'Test-FmBackendCmuxAppAncestor',
    'Get-FmBackendName', 'Test-FmBackendValid', 'Test-FmBackendSpawnValid',
    'Get-FmBackendRequiredTool', 'Test-FmBackendRequiredTool',
    'Get-FmBackendOfMeta', 'Get-FmBackendTargetOfMeta',
    'Get-FmBackendMetaExactValue', 'Get-FmBackendMetaKeyCount',
    'Test-FmBackendEndpointAtom', 'Get-FmBackendValidatedEndpoint',
    'Get-FmBackendMetaForWindow', 'Get-FmBackendTaskIdForSelector',
    'Get-FmBackendMetaForSelector', 'Get-FmBackendOfSelector',
    'Get-FmBackendExpectedLabelOfSelector',
    'Import-FmBackendAdapter', 'Resolve-FmBackendSelector',
    'Get-FmBackendCapture', 'Send-FmBackendKey', 'Send-FmBackendTextSubmit',
    'Remove-FmBackendTarget', 'Remove-FmBackendWorktree', 'Get-FmBackendWorktreePath',
    'Get-FmBackendBusyState', 'Get-FmBackendComposerState',
    'Test-FmBackendTargetExists', 'Get-FmBackendAgentState', 'Get-FmBackendAgentAlive',
    'Test-FmBackendHasPush', 'Test-FmBackendEventsCapable',
    'Wait-FmBackendTransition', 'Save-FmBackendTransition', 'Clear-FmBackendTransition'
)
