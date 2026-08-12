#requires -Version 7.0
# module/Firstmate/Private/FmBackendHerdr.ps1 - the Herdr session-provider
# adapter for native Windows PowerShell, ported from bin/backends/herdr.sh in
# the bash firstmate (reference: /home/adit-admin/dhaval_first_test/firstmate).
#
# This file also carries two smaller ports that the brief assigns to this area
# but that have no file of their own in the agreed module layout, each in its
# own clearly delimited section at the bottom:
#   - the backend-neutral task-metadata, selector, and endpoint-validation
#     layer from bin/fm-backend.sh, and
#   - the control-plane capability tables from bin/fm-control-lib.sh.
# FUTURE SPLIT: when the module layout gains Private/FmBackend.ps1 and
# Private/FmControl.ps1, move those two sections there verbatim. They live here
# only so this worker creates exactly the files its brief names.
#
# Herdr is a session provider ONLY: the worktree provider stays treehouse
# (Private/FmWorktree.ps1), exactly as on the bash side.
#
# WHAT IS PORTED (the core loop this brief owns): create a pane, send text and
# keys, capture output, read agent state, tear down. Concretely:
#   container ensure (version gate -> server ensure -> workspace resolve),
#   task tab/pane creation with husk replacement, target parsing, literal and
#   submitted text, named keys, bounded capture, native agent-state reads
#   (busy/idle and the recovery-grade alive/dead/missing classifier), verified
#   submit, pane close, and live-task discovery by label.
#
# WHAT IS DELIBERATELY NOT PORTED (see docs/herdr-backend-windows.md for the
# full rationale, each is out of this brief's scope, not an oversight):
#   - the presentation-space projection (disposable per-task workspaces), its
#     version floor, its journal, the focus-preserving close plan, and the
#     per-session presentation lock. Without projection the kill path is the
#     bash adapter's own documented fallback: one explicit close confirmed by a
#     structured presence read.
#   - the native pane.agent_status_changed push subscriber (fm_backend_herdr_
#     wait_transition). That is the watcher's event fast path; polling is the
#     permanent fail-closed backstop on the bash side too.
#   - composer SHAPE classification. bin/fm-composer-lib.sh is explicitly the
#     one fleet-wide owner shared by every adapter; this adapter stays the thin
#     consumer that design requires - it captures a screen, describes its
#     capabilities, and delegates the verdict (see Get-FmHerdrComposerState).
#
# DIFFERENCES FROM THE BASH ADAPTER THAT ARE IMPROVEMENTS, NOT DRIFT:
#   - No jq. Herdr's JSON is parsed with ConvertFrom-Json, so a Windows home
#     needs only the herdr CLI itself. Every `.a.b.c // empty` jq expression
#     becomes Get-FmJsonValue, which is strict-mode safe.
#   - No shell. Every CLI call goes through Invoke-FmChildProcess
#     (System.Diagnostics.Process), so arguments are passed as an argv array
#     and never re-parsed by a shell.
#
# WINDOWS-UNVERIFIED: every function that talks to a live herdr server. Herdr
# ships a Windows preview and this repo measured its core loop passing on a
# Windows runner, but this port's own calls have not been executed against a
# Windows herdr server; the tests below drive the adapter through a fake CLI.

Set-StrictMode -Version Latest

# The verified minimum herdr wire protocol. Matches FM_BACKEND_HERDR_MIN_PROTOCOL.
$script:FmHerdrMinProtocol = 14

# .fm-secondmate-home is written at a seeded secondmate home's root and holds
# exactly that secondmate's id. The primary home never carries it.
$script:FmHerdrSecondmateMarker = '.fm-secondmate-home'

# How many agent-state samples a submit attempt spreads across its confirmation
# budget, and the floor for that budget. Mirrors FM_BACKEND_HERDR_SUBMIT_POLLS
# and FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP; overridable for tests.
$script:FmHerdrSubmitPolls = 6
$script:FmHerdrSubmitMinSleep = 0.6

# Rows a composer read captures. Mirrors FM_COMPOSER_CAPTURE_LINES' role.
$script:FmHerdrComposerCaptureLines = 40

# --- generic process and JSON helpers ---------------------------------------
#
# MERGE POINT: Invoke-FmChildProcess and Get-FmJsonValue are general-purpose.
# They live here because this file is the first that needed them; if the
# foundation module grows its own equivalents, keep one and delete the other
# rather than letting two shapes drift.

# Invoke-FmChildProcess: run one native command with an argv array, no shell
# anywhere. Never throws for a failed or missing binary - callers branch on the
# returned record, exactly as the bash adapter branches on exit status and
# response body. StdErr is kept separate from StdOut because herdr writes
# business-logic errors as JSON on stdout while diagnostics go to stderr.
function Invoke-FmChildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = '',
        [double]$TimeoutSeconds = 0,
        # Text to hand the child on stdin before it is closed. Without it stdin
        # is closed immediately, which is what every CLI call here wants; with
        # it, a filter like `git patch-id --stable` can be fed without a shell
        # pipe. Written before the output readers start, so it must stay small
        # enough not to fill the pipe buffer - which is true of every use here.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$StandardInput
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($PSBoundParameters.ContainsKey('StandardInput')) {
        $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        $psi.Environment[[string]$key] = [string]$Environment[$key]
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        $null = $proc.Start()
    } catch {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = -1
            StdOut   = ''
            StdErr   = "could not start '$FilePath': $($_.Exception.Message)"
            Combined = ''
            TimedOut = $false
        }
    }

    try {
        # Readers first, THEN stdin: a child that writes while we are still
        # feeding it would otherwise deadlock on a full stdout pipe.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($PSBoundParameters.ContainsKey('StandardInput') -and $null -ne $StandardInput) {
            $proc.StandardInput.Write($StandardInput)
        }
        $proc.StandardInput.Close()
        $timedOut = $false
        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit([int]([math]::Ceiling($TimeoutSeconds * 1000)))) {
                $timedOut = $true
                try { $proc.Kill($true) } catch { Write-Debug "herdr: kill after timeout failed (the process had already exited): $_" }
                $proc.WaitForExit()
            }
        } else {
            $proc.WaitForExit()
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    [pscustomobject]@{
        Ok       = (-not $timedOut -and $code -eq 0)
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
        Combined = ($stdout + $stderr)
        TimedOut = $timedOut
    }
}

# Get-FmJsonValue: strict-mode-safe dotted-path read over a ConvertFrom-Json
# object. Returns $null when any hop is absent - the direct equivalent of jq's
# `.a.b.c // empty`, which every call site in the bash adapter relies on.
function Get-FmJsonValue {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $node = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) {
            if (-not $node.Contains($segment)) { return $null }
            $node = $node[$segment]
            continue
        }
        $prop = $node.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    # An array is returned wrapped so PowerShell's pipeline unrolling gives the
    # caller the array itself. Without this an EMPTY array would unroll to
    # nothing and read as $null - which is how a legitimate "this workspace has
    # no tabs" answer would be mistaken for "the response was unparseable", the
    # exact distinction jq's `(.result.tabs | type) == "array"` draws.
    if ($node -is [System.Array]) { return , $node }
    $node
}

# ConvertFrom-FmJsonSafe: parse or return $null. Herdr occasionally answers a
# non-JSON diagnostic; an unparseable body must degrade to "unknown", never to
# a thrown exception under $ErrorActionPreference = 'Stop'.
function ConvertFrom-FmJsonSafe {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

# --- herdr CLI plumbing ------------------------------------------------------

# Get-FmHerdrSession: which named herdr session this operation uses.
# HERDR_SESSION mirrors tmux's $TMUX ambient selection; absent means herdr's
# own "default" session.
function Get-FmHerdrSession {
    [OutputType([string])]
    [CmdletBinding()]
    param()
    if ($env:HERDR_SESSION) { return $env:HERDR_SESSION }
    'default'
}

# Invoke-FmHerdrCli: run `herdr <args...> --session <name>`, setting BOTH the
# HERDR_SESSION environment variable AND the trailing --session flag.
# Verified on the bash side (docs/herdr-backend.md "Session targeting"): the
# env var alone is NOT reliably honored once another herdr server is bound on
# the machine - queries silently fall back to whatever server IS running. The
# trailing flag always routes correctly. Keeping both is harmless and
# self-documenting.
function Invoke-FmHerdrCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TimeoutSeconds = 30
    )
    $argv = @($Arguments) + @('--session', $Session)
    Invoke-FmChildProcess -FilePath 'herdr' -ArgumentList $argv `
        -Environment @{ HERDR_SESSION = $Session } -TimeoutSeconds $TimeoutSeconds
}

# Invoke-FmHerdrCliJson: an Invoke-FmHerdrCli call whose stdout is parsed.
# Returns $null when the call failed to produce parseable JSON. Herdr answers
# business-logic failures ("pane_not_found") as JSON with a nonzero exit, so
# the body is parsed regardless of exit code and callers classify from the
# body - never from process exit status.
function Invoke-FmHerdrCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TimeoutSeconds = 30
    )
    $result = Invoke-FmHerdrCli -Session $Session -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    $json = ConvertFrom-FmJsonSafe -Text $result.StdOut
    if ($null -eq $json) { $json = ConvertFrom-FmJsonSafe -Text $result.Combined }
    $json
}

# Assert-FmHerdrTool: refuse loudly if the herdr CLI is missing. Unlike the
# bash adapter there is no jq requirement on this port - herdr's JSON is parsed
# natively - so the herdr binary is the whole dependency.
#
# These two are Assert-, not Test-, deliberately: a missing or too-old CLI is a
# hard blocker in every context, and a throw behaves the same whatever the
# caller's $ErrorActionPreference happens to be. A Write-Error would be
# terminating under the module's own 'Stop' preference and non-terminating
# under a caller's 'Continue', which is exactly the kind of
# refusal-that-might-not-refuse this port must not have.
function Assert-FmHerdrTool {
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    if (Get-Command herdr -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    throw "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev)"
}

# Assert-FmHerdrVersion: refuse loudly on a missing or too-old herdr client.
# Reads .client.protocol, which is session-independent (unlike .server).
function Assert-FmHerdrVersion {
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    $null = Assert-FmHerdrTool
    $result = Invoke-FmChildProcess -FilePath 'herdr' -ArgumentList @('status', '--json') -TimeoutSeconds 30
    $json = ConvertFrom-FmJsonSafe -Text $result.StdOut
    if ($null -eq $json) {
        throw "error: 'herdr status --json' failed; is herdr installed correctly?"
    }
    $protocol = Get-FmJsonValue -InputObject $json -Path 'client.protocol'
    $version = Get-FmJsonValue -InputObject $json -Path 'client.version'
    if ($null -eq $protocol -or -not ([int]::TryParse([string]$protocol, [ref]([int]0)))) {
        throw "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build"
    }
    if ([int]$protocol -lt $script:FmHerdrMinProtocol) {
        $shown = if ($version) { $version } else { 'unknown' }
        throw "error: herdr protocol $protocol (version $shown) is older than the verified minimum $($script:FmHerdrMinProtocol); update herdr before using backend=herdr"
    }
    $true
}

# Get-FmHerdrWorkspaceLabel: the per-firstmate-HOME workspace label. The
# PRIMARY home resolves to the constant "firstmate", byte-identical to every
# pre-existing task's recorded label. A SECONDMATE home resolves to
# "2ndmate-<id>". Read fresh from FM_HOME on every call, never cached, so the
# label stays stable for the life of that home.
function Get-FmHerdrWorkspaceLabel {
    [OutputType([string])]
    [CmdletBinding()]
    param([string]$HomePath = '')
    if (-not $HomePath) { $HomePath = $env:FM_HOME }
    if ($HomePath) {
        $marker = Join-Path $HomePath $script:FmHerdrSecondmateMarker
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $id = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)
            if ($null -ne $id) {
                $id = ($id -replace '\s', '')
                if ($id) { return "2ndmate-$id" }
            }
        }
    }
    'firstmate'
}

# Start-FmHerdrServer: start the herdr server for <Session> headless if it is
# not already running, mirroring `tmux has-session || tmux new-session -d`.
# A bare CLI call does NOT auto-start the server, so this must run before any
# workspace/tab/pane call. Bounded poll for the server to report running.
function Start-FmHerdrServer {
    [OutputType([bool])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Session,
        [int]$Polls = 20,
        [double]$PollSeconds = 0.5
    )
    if (Test-FmHerdrServerRunning -Session $Session) { return $true }
    if (-not $PSCmdlet.ShouldProcess("herdr session '$Session'", 'start server')) { return $false }
    # Detached: the server is a long-lived process, so it must not be waited on.
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'herdr'
        foreach ($a in @('server', '--session', $Session)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['HERDR_SESSION'] = $Session
        $null = [System.Diagnostics.Process]::Start($psi)
    } catch {
        # -ErrorAction Continue, not a throw: this reports a verdict its
        # callers branch on (a send to a dead session becomes 'send-failed'),
        # so it must not terminate under the module's 'Stop' preference.
        Write-Error "could not start the herdr server for session '$Session': $($_.Exception.Message)" -ErrorAction Continue
        return $false
    }
    for ($i = 0; $i -lt $Polls; $i++) {
        if (Test-FmHerdrServerRunning -Session $Session) { return $true }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Error "herdr server for session '$Session' did not report running within $([math]::Round($Polls * $PollSeconds, 1))s" -ErrorAction Continue
    $false
}

function Test-FmHerdrServerRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session)
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('status', '--json')
    ((Get-FmJsonValue -InputObject $json -Path 'server.running') -eq $true)
}

# --- workspace resolution ----------------------------------------------------

# Get-FmHerdrWorkspaceIdAll: EVERY workspace id in <Session> whose label equals
# this HOME's own label, in herdr's own list order. Herdr enforces NO workspace
# label uniqueness, so this can legitimately return more than one id; callers
# decide what a duplicate means for them.
function Get-FmHerdrWorkspaceIdAll {
    [OutputType([array], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [string]$Label = ''
    )
    if (-not $Label) { $Label = Get-FmHerdrWorkspaceLabel }
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('workspace', 'list')
    $workspaces = Get-FmJsonValue -InputObject $json -Path 'result.workspaces'
    if ($null -eq $workspaces) { return @() }
    @(foreach ($ws in $workspaces) {
        if ((Get-FmJsonValue -InputObject $ws -Path 'label') -ceq $Label) {
            $id = Get-FmJsonValue -InputObject $ws -Path 'workspace_id'
            if ($id) { [string]$id }
        }
    })
}

# Get-FmHerdrWorkspaceId: this home's workspace id, first match, read-only.
# Safe for recovery and list paths, which address panes they already recorded
# and only need a container to scan. NOT the spawn-time resolver.
function Get-FmHerdrWorkspaceId {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session)
    $all = @(Get-FmHerdrWorkspaceIdAll -Session $Session)
    if ($all.Count -ge 1) { return $all[0] }
    ''
}

# Get-FmHerdrLauncherIdentity: the EXACT herdr workspace the process making
# this spawn is itself running in.
#
# Herdr injects HERDR_ENV/HERDR_PANE_ID/HERDR_SESSION/HERDR_SOCKET_PATH into
# every process it manages a pane for. The injected HERDR_TAB_ID and
# HERDR_WORKSPACE_ID are deliberately NOT trusted as the answer: they are a
# snapshot from pane-process start, and herdr can move a pane between tabs and
# workspaces afterwards without rewriting a running process's environment. Only
# a live read is the CURRENT parent, which is what placement must bind to.
#
# Returns a record with Status = 'resolved' | 'none' | 'refused':
#   resolved - one exact, self-consistent launcher pane/tab/workspace.
#   none     - this process is not running in a herdr pane at all; the caller
#              falls back to its per-home container.
#   refused  - a launcher pane IS claimed but its binding is missing, stale,
#              contradictory, or belongs to another herdr session. The caller
#              must refuse before creating any worker endpoint rather than
#              degrading to a label search.
function Get-FmHerdrLauncherIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session)

    $refuse = {
        param($Message)
        [pscustomobject]@{ Status = 'refused'; Reason = $Message; PaneId = ''; TabId = ''; WorkspaceId = '' }
    }
    $pane = $env:HERDR_PANE_ID
    if (-not $pane) {
        return [pscustomobject]@{ Status = 'none'; Reason = ''; PaneId = ''; TabId = ''; WorkspaceId = '' }
    }

    # Same-session proof, before the pane id is trusted at all: herdr pane ids
    # restart at the same low numbers in every session, so a pane id borrowed
    # from another session can silently resolve to a real but unrelated
    # workspace here.
    $claimedSession = Get-FmHerdrSession
    if ($claimedSession -ne $Session) {
        return & $refuse "herdr launcher pane '$pane' reports session '$claimedSession' but this spawn targets session '$Session'; refusing to place a worker from a cross-session parent identity"
    }
    if (-not $env:HERDR_SOCKET_PATH) {
        return & $refuse "herdr launcher pane '$pane' has no injected socket identity; refusing to place a worker from an unverifiable parent identity"
    }
    $claimedSocket = Get-FmHerdrCanonicalSocketPath -SocketPath $env:HERDR_SOCKET_PATH
    if (-not $claimedSocket) {
        return & $refuse "herdr launcher pane '$pane' reports an unusable socket path; refusing to place a worker from an unverifiable parent identity"
    }
    $sessionSocket = Get-FmHerdrSessionSocketPath -Session $Session
    if (-not $sessionSocket) {
        return & $refuse "herdr session '$Session' has no unambiguous socket to match against the launcher pane's own; refusing to place a worker from an unverifiable parent identity"
    }
    if (-not (Test-FmPathEqual -Left $claimedSocket -Right $sessionSocket)) {
        return & $refuse "herdr launcher pane '$pane' belongs to the server at '$claimedSocket', not session '$Session' at '$sessionSocket'; refusing to place a worker from a cross-session parent identity"
    }

    $paneJson = Invoke-FmHerdrCliJson -Session $Session -Arguments @('pane', 'get', $pane)
    if ((Get-FmJsonValue -InputObject $paneJson -Path 'result.pane.pane_id') -ne $pane) {
        return & $refuse "herdr launcher pane '$pane' could not be read in session '$Session'; refusing to place a worker without its exact parent workspace"
    }
    $tab = [string](Get-FmJsonValue -InputObject $paneJson -Path 'result.pane.tab_id')
    $workspace = [string](Get-FmJsonValue -InputObject $paneJson -Path 'result.pane.workspace_id')
    if (-not $tab -or -not $workspace) {
        return & $refuse "herdr launcher pane '$pane' returned an ambiguous tab or workspace identity in session '$Session'; refusing to place a worker without its exact parent workspace"
    }

    # Independent second read: the tab must agree it lives in the same
    # workspace the pane just claimed.
    $tabJson = Invoke-FmHerdrCliJson -Session $Session -Arguments @('tab', 'get', $tab)
    if ((Get-FmJsonValue -InputObject $tabJson -Path 'result.tab.tab_id') -ne $tab -or
        (Get-FmJsonValue -InputObject $tabJson -Path 'result.tab.workspace_id') -ne $workspace) {
        return & $refuse "herdr launcher pane '$pane' and tab '$tab' disagree about their workspace in session '$Session'; refusing to place a worker from a contradictory parent identity"
    }

    $listJson = Invoke-FmHerdrCliJson -Session $Session -Arguments @('workspace', 'list')
    $workspaces = Get-FmJsonValue -InputObject $listJson -Path 'result.workspaces'
    if ($null -eq $workspaces) {
        return & $refuse "could not list herdr workspaces in session '$Session' to confirm the launcher's own workspace '$workspace'; refusing to place a worker without its exact parent workspace"
    }
    $hits = @($workspaces | Where-Object { (Get-FmJsonValue -InputObject $_ -Path 'workspace_id') -eq $workspace })
    if ($hits.Count -ne 1) {
        return & $refuse "herdr launcher workspace '$workspace' is missing or duplicated in session '$Session'; refusing to place a worker from a stale parent identity"
    }

    [pscustomobject]@{
        Status      = 'resolved'
        Reason      = ''
        PaneId      = $pane
        TabId       = $tab
        WorkspaceId = $workspace
    }
}

# Get-FmHerdrCanonicalSocketPath: normalize one absolute socket path so two
# spellings of the same socket compare equal. Refuses a relative or empty path.
# An unresolvable directory is left as-is rather than treated as a failure.
function Get-FmHerdrCanonicalSocketPath {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$SocketPath)
    if (-not $SocketPath) { return '' }
    if (-not [System.IO.Path]::IsPathRooted($SocketPath)) { return '' }
    $dir = [System.IO.Path]::GetDirectoryName($SocketPath)
    $base = [System.IO.Path]::GetFileName($SocketPath)
    if (-not $dir -or -not $base) { return '' }
    $realDir = Resolve-FmPhysicalPath -Path $dir
    if (-not $realDir) { return $SocketPath }
    Join-Path $realDir $base
}

# Get-FmHerdrSessionSocketPath: the one verified running named-session socket
# path. Requires exactly one running session of that name carrying a non-empty
# string socket_path.
function Get-FmHerdrSessionSocketPath {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session)
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('session', 'list', '--json')
    $sessions = Get-FmJsonValue -InputObject $json -Path 'sessions'
    if ($null -eq $sessions) { return '' }
    $running = @(foreach ($s in $sessions) {
        if ((Get-FmJsonValue -InputObject $s -Path 'name') -eq $Session -and
            (Get-FmJsonValue -InputObject $s -Path 'running') -eq $true) {
            $socket = Get-FmJsonValue -InputObject $s -Path 'socket_path'
            if ($socket -is [string] -and $socket.Length -gt 0) { $socket }
        }
    })
    if ($running.Count -ne 1) { return '' }
    Get-FmHerdrCanonicalSocketPath -SocketPath $running[0]
}

# Resolve-FmHerdrWorkspace: the workspace this spawn's task tab belongs in -
# the launching agent's own exact workspace when it has one, otherwise this
# HOME's persistent workspace, created in <Cwd> if absent.
#
# <Relationship>:
#   launcher-home - a crewmate or scout for the caller's own home. When the
#                   caller is itself in a herdr pane, the worker MUST land in
#                   that exact workspace, never in whichever same-labeled
#                   workspace happens to sort first.
#   other-home    - a secondmate launch, which stands up a DIFFERENT home's own
#                   per-home workspace by design.
#
# Returns a record with Status = 'resolved' | 'refused' | 'failed', the
# WorkspaceId, and SeededTabId - non-empty ONLY when THIS call just CREATED the
# workspace (the tab_id of the auto-created default tab, read straight from the
# create response). An ADOPTED workspace always reports an empty SeededTabId,
# and its tabs are never inspected for pruning no matter how they are labeled.
function Resolve-FmHerdrWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$Cwd,
        [ValidateSet('launcher-home', 'other-home')][string]$Relationship = 'launcher-home'
    )
    $result = [pscustomobject]@{ Status = 'failed'; Reason = ''; WorkspaceId = ''; SeededTabId = '' }

    if ($Relationship -eq 'launcher-home') {
        $launcher = Get-FmHerdrLauncherIdentity -Session $Session
        switch ($launcher.Status) {
            'resolved' {
                $result.Status = 'resolved'
                $result.WorkspaceId = $launcher.WorkspaceId
                return $result
            }
            'refused' {
                $result.Status = 'refused'
                $result.Reason = $launcher.Reason
                return $result
            }
        }
    }

    $label = Get-FmHerdrWorkspaceLabel
    $labeled = @(Get-FmHerdrWorkspaceIdAll -Session $Session -Label $label)
    if ($labeled.Count -gt 1) {
        $result.Status = 'refused'
        $result.Reason = "$($labeled.Count) herdr workspaces in session '$Session' are labeled '$label' ($($labeled -join ' ')) and this spawn has no herdr parent pane to identify which one is its own; rename or close the extras, or run firstmate inside the workspace its workers belong in"
        return $result
    }
    if ($labeled.Count -eq 1) {
        $result.Status = 'resolved'
        $result.WorkspaceId = $labeled[0]
        return $result
    }

    # --no-focus: workspace create does not focus by default once at least one
    # workspace exists; passed unconditionally for defense in depth.
    $json = Invoke-FmHerdrCliJson -Session $Session `
        -Arguments @('workspace', 'create', '--cwd', $Cwd, '--label', $label, '--no-focus')
    $wsid = [string](Get-FmJsonValue -InputObject $json -Path 'result.workspace.workspace_id')
    if (-not $wsid) {
        $result.Reason = "failed to create herdr workspace '$label' in session '$Session'"
        return $result
    }
    $result.Status = 'resolved'
    $result.WorkspaceId = $wsid
    # Herdr seeds a new workspace with one auto-created default tab firstmate
    # never uses. It is NOT pruned here: at this instant it is the workspace's
    # ONLY tab, and closing a workspace's last tab deletes the workspace itself.
    # New-FmHerdrTask prunes it once a real task tab exists alongside it.
    $result.SeededTabId = [string](Get-FmJsonValue -InputObject $json -Path 'result.tab.tab_id')
    $result
}

# New-FmHerdrContainer: the full spawn-time container-ensure sequence (version
# gate, server, workspace). Returns a record with Session, WorkspaceId,
# SeededTabId and Container ("<session>:<workspace_id>"), or throws with the
# exact refusal so a caller never guesses a placement.
function New-FmHerdrContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [ValidateSet('launcher-home', 'other-home')][string]$Relationship = 'launcher-home'
    )
    $null = Assert-FmHerdrVersion
    $session = Get-FmHerdrSession
    if (-not $PSCmdlet.ShouldProcess("herdr session '$session'", 'ensure container')) { return $null }
    if (-not (Start-FmHerdrServer -Session $session)) { throw "herdr server for session '$session' is not running" }
    $workspace = Resolve-FmHerdrWorkspace -Session $session -Cwd $Cwd -Relationship $Relationship
    if ($workspace.Status -ne 'resolved') {
        throw $workspace.Reason
    }
    [pscustomobject]@{
        Session     = $session
        WorkspaceId = $workspace.WorkspaceId
        SeededTabId = $workspace.SeededTabId
        Container   = "$session`:$($workspace.WorkspaceId)"
    }
}

# --- pane and agent state ----------------------------------------------------

# Get-FmHerdrPanePresenceState: classify one exact `pane get` response as
# dead|present|unknown from its JSON body, never from process exit status - a
# business-logic "not found" is a normal outcome here, not a call failure.
function Get-FmHerdrPanePresenceState {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$PaneId
    )
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('pane', 'get', $PaneId)
    $code = Get-FmJsonValue -InputObject $json -Path 'error.code'
    if ($code) {
        if ($code -eq 'pane_not_found') { return 'dead' }
        return 'unknown'
    }
    if ((Get-FmJsonValue -InputObject $json -Path 'result.pane.pane_id') -eq $PaneId) { return 'present' }
    'unknown'
}

# Get-FmHerdrPaneAgentState: dead|no-agent|live|unknown, purely from the JSON
# bodies of two read-only calls.
#   dead     - the pane itself is gone (closed, or its process died).
#   no-agent - the pane exists but nothing is registered in it: exactly what a
#              herdr session-layout restore leaves behind.
#   live     - a registered agent reporting any real status.
#   unknown  - anything else. Callers must fail safe toward refusal here.
function Get-FmHerdrPaneAgentState {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$PaneId
    )
    $presence = Get-FmHerdrPanePresenceState -Session $Session -PaneId $PaneId
    if ($presence -ne 'present') {
        if ($presence -eq 'dead') { return 'dead' }
        return 'unknown'
    }
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('agent', 'get', $PaneId)
    $code = Get-FmJsonValue -InputObject $json -Path 'error.code'
    if ($code) {
        if ($code -eq 'agent_not_found') { return 'no-agent' }
        return 'unknown'
    }
    switch ([string](Get-FmJsonValue -InputObject $json -Path 'result.agent.agent_status')) {
        'working' { 'live' }
        'idle'    { 'live' }
        'done'    { 'live' }
        'blocked' { 'live' }
        default   { 'unknown' }
    }
}

# Test-FmHerdrTabIsHusk: true only for the two conservative husk states this
# adapter can positively confirm; live and unknown both refuse, so an
# inconclusive read never licenses closing anything.
function Test-FmHerdrTabIsHusk {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$PaneId
    )
    (Get-FmHerdrPaneAgentState -Session $Session -PaneId $PaneId) -in @('dead', 'no-agent')
}

# Get-FmHerdrAgentState: the recovery-grade state contract, one of
# alive|dead|missing|unreadable. Only dead and missing license recovery.
function Get-FmHerdrAgentState {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return 'unreadable' }
    switch (Get-FmHerdrPaneAgentState -Session $parsed.Session -PaneId $parsed.PaneId) {
        'dead'     { 'missing' }
        'no-agent' { 'dead' }
        'live'     { 'alive' }
        default    { 'unreadable' }
    }
}

# --- target addressing -------------------------------------------------------

# Split-FmHerdrTarget: split "<session>:<pane_id>" on the FIRST colon only -
# the pane id itself contains a colon, e.g. "default:w1:p2". Returns $null for
# a malformed target.
function Split-FmHerdrTarget {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Target)
    if (-not $Target) { return $null }
    $idx = $Target.IndexOf(':')
    if ($idx -le 0 -or $idx -ge ($Target.Length - 1)) { return $null }
    [pscustomobject]@{
        Session = $Target.Substring(0, $idx)
        PaneId  = $Target.Substring($idx + 1)
    }
}

# Test-FmHerdrTargetReady: parse the target and ensure its session's server is
# up. Every ACTIVE operation (send/capture) goes through this; the passive
# liveness probe below deliberately does not, so a read never starts a server.
function Test-FmHerdrTargetReady {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return $false }
    Start-FmHerdrServer -Session $parsed.Session -Confirm:$false
}

# Test-FmHerdrTargetExists: cheap, READ-ONLY existence check. Never starts a
# server: it queries the pane directly, so a passive liveness probe cannot have
# the side effect of resurrecting a session.
function Test-FmHerdrTargetExists {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return $false }
    (Get-FmHerdrPanePresenceState -Session $parsed.Session -PaneId $parsed.PaneId) -eq 'present'
}

# Get-FmHerdrCurrentPath: the live FOREGROUND process's cwd, or empty.
#
# Verified pitfall carried over from the bash adapter: `.result.pane.cwd` is
# the pane's cwd AT CREATION TIME and does NOT update when that shell cd's or
# enters a subshell. `.result.pane.foreground_cwd` tracks the actually running
# foreground process's cwd, which is what changes. This port acquires its
# worktree with `treehouse get --lease` rather than by scraping this value, so
# nothing depends on it for isolation any more; it is kept for diagnostics and
# for the relaunch check that an adopted endpoint really sits in its worktree.
function Get-FmHerdrCurrentPath {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return '' }
    $parsed = Split-FmHerdrTarget -Target $Target
    $json = Invoke-FmHerdrCliJson -Session $parsed.Session -Arguments @('pane', 'get', $parsed.PaneId)
    [string](Get-FmJsonValue -InputObject $json -Path 'result.pane.foreground_cwd')
}

# Get-FmHerdrPaneCreationPath: the pane's `cwd`, which herdr freezes at creation
# and does not move on a `cd`. That makes it useless for "where is this shell
# now" - the reason Get-FmHerdrCurrentPath reads foreground_cwd instead - but it
# is exactly the right field for "was this pane created where we asked", and it
# is the only reading available on a platform whose live foreground cwd comes
# back empty (MEASURED on Windows herdr; data/fmwin-design/report.md section 3.2).
function Get-FmHerdrPaneCreationPath {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return '' }
    $parsed = Split-FmHerdrTarget -Target $Target
    $json = Invoke-FmHerdrCliJson -Session $parsed.Session -Arguments @('pane', 'get', $parsed.PaneId)
    [string](Get-FmJsonValue -InputObject $json -Path 'result.pane.cwd')
}

# --- task creation -----------------------------------------------------------

# Get-FmHerdrPaneForTab: the root pane id for <TabId>, via one pane list call
# filtered by tab_id. Never assumes a tab-number/pane-number correspondence -
# herdr numbers them independently.
function Get-FmHerdrPaneForTab {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$TabId
    )
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('pane', 'list', '--workspace', $WorkspaceId)
    $panes = Get-FmJsonValue -InputObject $json -Path 'result.panes'
    if ($null -eq $panes) { return '' }
    foreach ($pane in $panes) {
        if ((Get-FmJsonValue -InputObject $pane -Path 'tab_id') -eq $TabId) {
            return [string](Get-FmJsonValue -InputObject $pane -Path 'pane_id')
        }
    }
    ''
}

# Remove-FmHerdrSeededDefaultTab: close EXACTLY the auto-created default tab id
# that THIS SAME container-ensure call captured from its own workspace-create
# response - never a tab re-derived from a label pattern.
#
# The bash original carries a live-fire incident here (2026-07-02): a
# label-only heuristic once closed a captain's own live pane 27ms after
# creating a task tab, because herdr enforces no label uniqueness and derives
# an unlabeled workspace's displayed label from its pane cwd's basename. The
# structural fix is preserved: only a workspace this same call just created
# carries a seeded tab id at all, so an adopted workspace's tabs are never even
# queried. The re-verification below (still present, still labeled "1", pane
# not hosting a working agent, and not the workspace's last tab) is defense in
# depth on top of that gate, not the primary mechanism.
function Remove-FmHerdrSeededDefaultTab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter()][AllowEmptyString()][string]$SeededTabId
    )
    if (-not $SeededTabId) { return }
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('tab', 'list', '--workspace', $WorkspaceId)
    $tabs = Get-FmJsonValue -InputObject $json -Path 'result.tabs'
    if ($null -eq $tabs) { return }
    $tabs = @($tabs)
    # Closing a workspace's LAST remaining tab deletes the whole workspace.
    if ($tabs.Count -le 1) { return }
    $seeded = @($tabs | Where-Object { (Get-FmJsonValue -InputObject $_ -Path 'tab_id') -eq $SeededTabId })
    if ($seeded.Count -ne 1) { return }
    if ((Get-FmJsonValue -InputObject $seeded[0] -Path 'label') -ne '1') { return }
    $paneId = Get-FmHerdrPaneForTab -Session $Session -WorkspaceId $WorkspaceId -TabId $SeededTabId
    if (-not $paneId) { return }
    $agent = Invoke-FmHerdrCliJson -Session $Session -Arguments @('agent', 'get', $paneId)
    if ((Get-FmJsonValue -InputObject $agent -Path 'result.agent.agent_status') -eq 'working') { return }
    if (-not $PSCmdlet.ShouldProcess("herdr pane $paneId", 'close seeded default tab')) { return }
    $null = Invoke-FmHerdrCli -Session $Session -Arguments @('pane', 'close', $paneId)
}

# New-FmHerdrTask: create the task's tab (one pane) in <Container>
# ("session:workspace_id"). Herdr does not enforce label uniqueness, so the
# duplicate check is ours, mirroring tmux's manual check.
#
# A same-labeled tab is not an automatic refusal: herdr persists and restores
# its whole session layout across a server restart, and a restored fm-<id> tab
# comes back a HUSK. A confirmed husk is CLOSED AND REPLACED; anything live or
# ambiguous still refuses.
#
# Ordering is deliberate: the REPLACEMENT tab is created FIRST and the husk is
# closed only after that succeeds - never the reverse, because closing a
# workspace's last remaining tab deletes the whole workspace.
#
# Returns a record with TabId, PaneId and Target ("<session>:<pane_id>").
function New-FmHerdrTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter()][AllowEmptyString()][string]$SeededTabId = ''
    )
    $parsed = Split-FmHerdrTarget -Target $Container
    if (-not $parsed) { throw "malformed herdr container '$Container'" }
    $session = $parsed.Session
    $wsid = $parsed.PaneId

    $listJson = Invoke-FmHerdrCliJson -Session $session -Arguments @('tab', 'list', '--workspace', $wsid)
    $tabs = Get-FmJsonValue -InputObject $listJson -Path 'result.tabs'
    if ($null -eq $tabs) {
        throw "could not parse herdr tab list output for workspace $wsid (session $session)"
    }
    $duplicates = @()
    foreach ($tab in @($tabs)) {
        if ((Get-FmJsonValue -InputObject $tab -Path 'label') -cne $Label) { continue }
        $dupTab = [string](Get-FmJsonValue -InputObject $tab -Path 'tab_id')
        $dupPane = Get-FmHerdrPaneForTab -Session $session -WorkspaceId $wsid -TabId $dupTab
        if (-not $dupPane -or -not (Test-FmHerdrTabIsHusk -Session $session -PaneId $dupPane)) {
            throw "herdr tab '$Label' already exists in workspace $wsid (session $session)"
        }
        $duplicates += $dupTab
    }

    if (-not $PSCmdlet.ShouldProcess("herdr workspace $wsid (session $session)", "create tab '$Label'")) {
        return $null
    }
    $createJson = Invoke-FmHerdrCliJson -Session $session `
        -Arguments @('tab', 'create', '--workspace', $wsid, '--cwd', $Cwd, '--label', $Label, '--no-focus')
    $tabId = [string](Get-FmJsonValue -InputObject $createJson -Path 'result.tab.tab_id')
    $paneId = [string](Get-FmJsonValue -InputObject $createJson -Path 'result.root_pane.pane_id')
    if (-not $tabId -or -not $paneId) {
        throw 'could not parse tab/pane id from herdr tab create output'
    }

    if ($SeededTabId) {
        Remove-FmHerdrSeededDefaultTab -Session $session -WorkspaceId $wsid -SeededTabId $SeededTabId -Confirm:$false
    }

    if ($duplicates.Count -gt 0) {
        foreach ($dup in $duplicates) {
            $null = Invoke-FmHerdrCli -Session $session -Arguments @('tab', 'close', $dup)
        }
        $verifyJson = Invoke-FmHerdrCliJson -Session $session -Arguments @('tab', 'list', '--workspace', $wsid)
        $verifyTabs = Get-FmJsonValue -InputObject $verifyJson -Path 'result.tabs'
        if ($null -eq $verifyTabs) {
            throw "could not verify herdr husk removal for tab '$Label' in workspace $wsid (session $session)"
        }
        $remaining = @(foreach ($tab in @($verifyTabs)) {
            $id = [string](Get-FmJsonValue -InputObject $tab -Path 'tab_id')
            if ((Get-FmJsonValue -InputObject $tab -Path 'label') -ceq $Label -and $id -ne $tabId) { $id }
        })
        if ($remaining.Count -gt 0) {
            throw "failed to remove preexisting herdr tab(s) $($remaining -join ' ') for label '$Label' in workspace $wsid (session $session)"
        }
    }

    [pscustomobject]@{
        Session = $session
        TabId   = $tabId
        PaneId  = $paneId
        Target  = "$session`:$paneId"
    }
}

# --- send, capture, submit ---------------------------------------------------

# Send-FmHerdrTextLine: send one line of text then submit, ATOMICALLY - the
# equivalent of tmux's `send-keys -t T text Enter`. Used for fixed spawn-time
# commands. `pane run` types the command and submits it in one call.
function Send-FmHerdrTextLine {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return $false }
    $parsed = Split-FmHerdrTarget -Target $Target
    (Invoke-FmHerdrCli -Session $parsed.Session -Arguments @('pane', 'run', $parsed.PaneId, $Text)).Ok
}

# Send-FmHerdrLiteral: send text as literal, UNSUBMITTED input - the caller
# sends Enter separately. `pane send-text` does not auto-submit; it behaves
# exactly like tmux's `send-keys -l`.
function Send-FmHerdrLiteral {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return $false }
    $parsed = Split-FmHerdrTarget -Target $Target
    (Invoke-FmHerdrCli -Session $parsed.Session -Arguments @('pane', 'send-text', $parsed.PaneId, $Text)).Ok
}

# ConvertTo-FmHerdrKey: map firstmate's key vocabulary onto herdr's
# `pane send-keys` names. Herdr is case-insensitive here; normalize explicitly
# rather than relying on that.
function ConvertTo-FmHerdrKey {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    switch -Regex ($Key) {
        '^(?i)enter$'            { return 'enter' }
        '^(?i)(escape|esc)$'     { return 'escape' }
        '^(?i)(c-c|ctrl\+c)$'    { return 'ctrl+c' }
        '^(?i)(c-u|ctrl\+u)$'    { return 'ctrl+u' }
        default                  { return $Key }
    }
}

function Send-FmHerdrKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return $false }
    $parsed = Split-FmHerdrTarget -Target $Target
    $key = ConvertTo-FmHerdrKey -Key $Key
    (Invoke-FmHerdrCli -Session $parsed.Session -Arguments @('pane', 'send-keys', $parsed.PaneId, $key)).Ok
}

# Get-FmHerdrCapture: bounded plain-text pane capture.
#
# Verified CLI quirk carried over: `pane read --source recent --lines N`
# returns COMPLETELY EMPTY output when N is smaller than the pane's current
# viewport height (~23 rows), instead of clamping. Workaround: always request a
# generous fetch far above any realistic viewport height, then trim to the
# caller's bound here.
function Get-FmHerdrCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Lines = 200,
        [switch]$Ansi
    )
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return $null }
    if ($Lines -le 0) { $Lines = 200 }
    $fetch = [math]::Max($Lines, 200)
    $parsed = Split-FmHerdrTarget -Target $Target
    $argv = @('pane', 'read', $parsed.PaneId, '--source', 'recent', '--lines', "$fetch")
    if ($Ansi) { $argv += @('--format', 'ansi') }
    $result = Invoke-FmHerdrCli -Session $parsed.Session -Arguments $argv
    if (-not $result.Ok) { return $null }
    $text = $result.StdOut -replace "`r`n", "`n"
    $all = $text.Split("`n")
    if ($all.Count -le $Lines) { return ($all -join "`n") }
    ($all[($all.Count - $Lines)..($all.Count - 1)] -join "`n")
}

# Get-FmHerdrAgentIdentity: the native agent identity/state probe - the genuine
# herdr primitive no other backend has natively. Returns "<agent>`t<status>".
function Get-FmHerdrAgentIdentity {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return '' }
    $json = Invoke-FmHerdrCliJson -Session $parsed.Session -Arguments @('agent', 'get', $parsed.PaneId)
    if ($null -eq $json) { return '' }
    $agent = [string](Get-FmJsonValue -InputObject $json -Path 'result.agent.agent')
    $status = [string](Get-FmJsonValue -InputObject $json -Path 'result.agent.agent_status')
    "$agent`t$status"
}

# Get-FmHerdrComposerState: the THIN adapter contract - capture a screen,
# describe the capture's capabilities, and hand both to the fleet-wide
# classifier. This port does not own that classifier (bin/fm-composer-lib.sh is
# explicitly the one fleet-wide owner, shared by every adapter), so when no
# Get-FmComposerState is loaded this returns 'unknown' rather than growing a
# private, drift-prone copy of the shape catalogue. 'unknown' is the fail-safe
# direction: every caller treats it as "cannot prove", never as "safe".
function Get-FmHerdrComposerState {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    $classifier = Get-Command -Name Get-FmComposerState -ErrorAction SilentlyContinue
    if (-not $classifier) { return 'unknown' }
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return 'unknown' }

    $styled = 1
    $capture = Get-FmHerdrCapture -Target $Target -Lines $script:FmHerdrComposerCaptureLines -Ansi
    if ($null -eq $capture) {
        $styled = 0
        $capture = Get-FmHerdrCapture -Target $Target -Lines $script:FmHerdrComposerCaptureLines
    }
    if ($null -eq $capture) { return 'unknown' }

    $caps = [ordered]@{
        styled   = $styled
        cursor   = 0
        identity = 1
        rows     = $script:FmHerdrComposerCaptureLines
    }
    $verdict = & $classifier -Capabilities $caps -Screen $capture
    if ($verdict -eq 'need-identity') {
        $identity = Get-FmHerdrAgentIdentity -Target $Target
        if (-not $identity) { $identity = 'probe-absent' }
        $verdict = & $classifier -Capabilities $caps -Screen $capture -Identity $identity
        if ($verdict -eq 'need-identity') { $verdict = 'unknown' }
    }
    [string]$verdict
}

# ConvertTo-FmHerdrBusyState: map a raw agent_status to the watcher's
# busy|idle|unknown vocabulary. working -> busy; idle/done -> idle; blocked ->
# idle (a blocked agent is stuck waiting on the human, not grinding, so the
# watcher must see it rather than suppress it as busy); anything else ->
# unknown, the caller's cue to fall back to pane-tail detection.
function ConvertTo-FmHerdrBusyState {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$AgentStatus)
    switch ($AgentStatus) {
        'working' { 'busy' }
        'idle'    { 'idle' }
        'done'    { 'idle' }
        'blocked' { 'idle' }
        default   { 'unknown' }
    }
}

# ConvertTo-FmHerdrSubmitState: the submit-confirmation view of the same raw
# status. A blocked agent HAS taken the input (it reached a prompt), so submit
# treats blocked as busy while the watcher treats it as idle.
function ConvertTo-FmHerdrSubmitState {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$AgentStatus)
    switch ($AgentStatus) {
        'working' { 'busy' }
        'blocked' { 'busy' }
        'idle'    { 'idle' }
        'done'    { 'idle' }
        default   { 'unknown' }
    }
}

# Get-FmHerdrAgentStatusRaw: one `agent get` read, echoing the raw
# agent_status string, or empty on any failure. Deliberately skips the
# server-ensure round trip that Get-FmHerdrBusyState pays, because the submit
# confirmation loop polls this immediately after a caller already proved the
# server live.
function Get-FmHerdrAgentStatusRaw {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$PaneId
    )
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('agent', 'get', $PaneId)
    if ($null -eq $json) { return '' }
    [string](Get-FmJsonValue -InputObject $json -Path 'result.agent.agent_status')
}

# Get-FmHerdrBusyState: semantic busy state from herdr's native agent-state
# detection - the one backend where this has real semantics beyond pane regex.
function Get-FmHerdrBusyState {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return 'unknown' }
    $parsed = Split-FmHerdrTarget -Target $Target
    ConvertTo-FmHerdrBusyState -AgentStatus (Get-FmHerdrAgentStatusRaw -Session $parsed.Session -PaneId $parsed.PaneId)
}

# Get-FmHerdrSubmitConfirmBudget: the per-Enter confirmation window, floored so
# a caller's very small sleep still leaves room for several samples.
function Get-FmHerdrSubmitConfirmBudget {
    [CmdletBinding()]
    param([double]$CallerBudgetSeconds = 0)
    $budget = [math]::Max($CallerBudgetSeconds, 0)
    [math]::Max($budget, $script:FmHerdrSubmitMinSleep)
}

# Wait-FmHerdrWorking: poll the pane's NATIVE agent-state up to <Polls> times
# spread across <BudgetSeconds>, returning the STRONGEST signal observed:
#   busy    - a submit-active status was observed at least once: the submit
#             landed, independent of whatever the composer's text shows.
#             Returned the instant it is seen.
#   idle    - the target was legibly read at least once and never reported
#             busy: a genuine "not (yet) submitted" signal. The caller retries
#             Enter on this verdict.
#   unknown - EVERY poll failed to read the target at all. The caller must not
#             keep retrying Enter against a target it cannot read.
#
# Spreading samples across the window (rather than one check at the end) is
# what makes this robust against a slow transition; real claude and codex were
# measured at 90-490ms to first `working`.
function Wait-FmHerdrWorking {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$PaneId,
        [double]$BudgetSeconds = 0.6,
        [int]$Polls = 6
    )
    if ($Polls -lt 1) { $Polls = 1 }
    $divisor = [math]::Max($Polls - 1, 1)
    $interval = [math]::Max($BudgetSeconds / $divisor, 0)
    $sawIdle = $false
    for ($i = 0; $i -lt $Polls; $i++) {
        if ($Polls -eq 1 -or $i -gt 0) { Start-Sleep -Seconds $interval }
        $state = ConvertTo-FmHerdrSubmitState -AgentStatus (Get-FmHerdrAgentStatusRaw -Session $Session -PaneId $PaneId)
        if ($state -eq 'busy') { return 'busy' }
        if ($state -eq 'idle') { $sawIdle = $true }
    }
    if ($sawIdle) { 'idle' } else { 'unknown' }
}

# Send-FmHerdrTextSubmit: type <Text> into <Target> ONCE (raw, unsubmitted),
# then submit with a named Enter, retried - Enter only, NEVER retyped - until
# herdr's native agent-state confirms a real turn started.
#
# Confirmation signal: when the target is legibly idle before Enter, submission
# is confirmed by observing a submit-active agent_status after Enter, not by
# reading the composer's own row. That makes the normal path cross-agent - the
# same semantic signal regardless of what a harness's idle composer displays -
# and it is what closed the bash side's 2026-07-07 redelivery-loop incident. It
# also handles the earlier slash-popup incident with no popup-specific logic:
# filling a completion placeholder never starts a turn, so the retry loop just
# sends another Enter.
#
# When the pre-Enter baseline is NOT legibly idle, confirmation falls back to
# the shared composer classifier, which this port does not own; absent that
# classifier the verdict is 'unknown' and the caller reports the steer as
# unconfirmed. That is the fail-closed direction the send contract requires.
#
# Echoes empty|pending|unknown|send-failed. Empty means confirmed submitted;
# how each backend confirms it is an internal decision.
function Send-FmHerdrTextSubmit {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$Retries = 3,
        [double]$EnterSleepSeconds = 0.4,
        [double]$SettleSeconds = 0.3
    )
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return 'unknown' }
    if (-not (Send-FmHerdrLiteral -Target $Target -Text $Text)) { return 'send-failed' }
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }

    $baseline = ConvertTo-FmHerdrSubmitState `
        -AgentStatus (Get-FmHerdrAgentStatusRaw -Session $parsed.Session -PaneId $parsed.PaneId)
    $confirmBudget = Get-FmHerdrSubmitConfirmBudget -CallerBudgetSeconds $EnterSleepSeconds

    $attempt = 0
    while ($true) {
        $null = Send-FmHerdrKey -Target $Target -Key 'Enter'
        if ($baseline -eq 'idle') {
            $verdict = Wait-FmHerdrWorking -Session $parsed.Session -PaneId $parsed.PaneId `
                -BudgetSeconds $confirmBudget -Polls $script:FmHerdrSubmitPolls
        } else {
            if ($EnterSleepSeconds -gt 0) { Start-Sleep -Seconds $EnterSleepSeconds }
            $verdict = Get-FmHerdrComposerState -Target $Target
        }
        switch ($verdict) {
            'busy'    { return 'empty' }
            'empty'   { return 'empty' }
            'unknown' { return 'unknown' }
        }
        $attempt++
        if ($attempt -ge $Retries) { return 'pending' }
    }
}

# --- teardown ----------------------------------------------------------------

# Remove-FmHerdrPane: remove the task's pane. Closing a tab's only pane closes
# the tab too, so no separate tab close is needed.
#
# NOT PORTED (see this file's header): the focus-preserving close plan and the
# per-session presentation lock, which exist only for the presentation-space
# projection. Without projection this is the bash adapter's own documented
# fallback - one explicit close whose success is proven by a structured
# presence read, never by exit status.
function Remove-FmHerdrPane {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return $false }
    if (-not (Test-FmHerdrTargetReady -Target $Target)) { return $false }
    if (-not $PSCmdlet.ShouldProcess("herdr pane $($parsed.PaneId) (session $($parsed.Session))", 'close')) {
        return $false
    }
    $null = Invoke-FmHerdrCli -Session $parsed.Session -Arguments @('pane', 'close', $parsed.PaneId)
    (Get-FmHerdrPanePresenceState -Session $parsed.Session -PaneId $parsed.PaneId) -eq 'dead'
}

# Test-FmHerdrEndpointGone: gate durable-record removal on the exact recorded
# pane's structured presence, read-only, so a refused, skipped, or failed close
# never erases a live task's endpoint identity. Only a structured
# pane_not_found proves the endpoint gone; present and unknown both refuse, and
# a malformed target is ambiguity that also refuses.
function Test-FmHerdrEndpointGone {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Target)
    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not $parsed) { return $false }
    (Get-FmHerdrPanePresenceState -Session $parsed.Session -PaneId $parsed.PaneId) -eq 'dead'
}

# --- discovery ---------------------------------------------------------------

# Get-FmHerdrLiveTask: recovery and orphan discovery. Lists every tab whose
# label looks like a firstmate task window (fm-<id>) in THIS HOME'S OWN
# workspace, by LABEL - never by trusting a stored pane id, since ids are not
# guaranteed stable across every server lifecycle. Read-only: a session or
# workspace that does not exist yet simply lists nothing.
function Get-FmHerdrLiveTask {
    [OutputType([array], [object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session)
    $wsid = Get-FmHerdrWorkspaceId -Session $Session
    if (-not $wsid) { return @() }
    $json = Invoke-FmHerdrCliJson -Session $Session -Arguments @('tab', 'list', '--workspace', $wsid)
    $tabs = Get-FmJsonValue -InputObject $json -Path 'result.tabs'
    if ($null -eq $tabs) { return @() }
    @(foreach ($tab in @($tabs)) {
        $label = [string](Get-FmJsonValue -InputObject $tab -Path 'label')
        if (-not $label.StartsWith('fm-')) { continue }
        $tabId = [string](Get-FmJsonValue -InputObject $tab -Path 'tab_id')
        $paneId = Get-FmHerdrPaneForTab -Session $Session -WorkspaceId $wsid -TabId $tabId
        if (-not $paneId) { continue }
        [pscustomobject]@{
            Target = "$Session`:$paneId"
            Label  = $label
            TabId  = $tabId
            PaneId = $paneId
        }
    })
}

# =============================================================================
# Task metadata, selectors, and endpoint validation
# (ported from bin/fm-backend.sh; see this file's header for the future split)
# =============================================================================

# LF, always. Windows PowerShell's default is CRLF and its default file
# encoding historically carried a BOM; either one breaks the byte-for-byte file
# contract that lets a Linux firstmate and this one read each other's state.
# Every durable record this port writes goes through these two helpers.
function Write-FmTextFileLf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $encoding)
}

function Add-FmTextLineLf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $flat = $Line -replace "`r`n", ' ' -replace "[`r`n]", ' '
    [System.IO.File]::AppendAllText($Path, $flat + "`n", $encoding)
}

# Add-FmStatusEvent: append one "<state>: <note>" wake event to
# state/<id>.status. A status line is a wake EVENT, not current-state truth -
# the same contract as the bash side.
#
# Add-FmTaskStatus (dispatch area) is the one owner of how a status line is
# formed, because it also owns the keyed decision grammar the fold reads. This
# delegates rather than keeping a second copy; it stays as the name the control
# plane already calls.
function Add-FmStatusEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Note
    )
    $owner = Get-Command -Name Add-FmTaskStatus -CommandType Function -ErrorAction SilentlyContinue
    if ($owner) {
        $null = & $owner -StateDir $StateDir -TaskId $TaskId -State $State -Note $Note -Confirm:$false
        return
    }
    $path = Join-Path $StateDir "$TaskId.status"
    Add-FmTextLineLf -Path $path -Line "$State`: $Note"
}

function Get-FmMetaPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir "$TaskId.meta"
}

# Get-FmMetaValue: the LAST value of `key=` in the meta file, or '' when the
# file or key is absent. Never errors - the fm_meta_get contract.
function Get-FmMetaValue {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $value = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1) }
    }
    $value
}

# Get-FmMetaExactValue: the value of `key=` only when it appears EXACTLY once
# and is non-empty; $null otherwise. Endpoint identity is validated with this,
# never with the last-wins read, so an ambiguous record refuses instead of
# resolving to whichever line came last.
function Get-FmMetaExactValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $hits = @(foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=")) { $line.Substring($Key.Length + 1) }
    })
    if ($hits.Count -ne 1) { return $null }
    if (-not $hits[0]) { return $null }
    $hits[0]
}

# Get-FmMetaBackend: the backend recorded in the meta file, defaulting to tmux
# when the field is absent - the compatibility contract that keeps a
# default-path meta byte-identical across implementations.
function Get-FmMetaBackend {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $value = Get-FmMetaValue -Path $Path -Key 'backend'
    if ($value) { return $value }
    'tmux'
}

function Get-FmMetaTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ((Get-FmMetaBackend -Path $Path) -eq 'orca') {
        $terminal = Get-FmMetaValue -Path $Path -Key 'terminal'
        if ($terminal) { return $terminal }
    }
    Get-FmMetaValue -Path $Path -Key 'window'
}

function Test-FmTaskIdShape {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$TaskId)
    if (-not $TaskId) { return $false }
    if ($TaskId.StartsWith('.')) { return $false }
    $TaskId -match '^[A-Za-z0-9._-]+$'
}

function Test-FmEndpointAtom {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    if (-not $Value) { return $false }
    $Value -match '^[A-Za-z0-9._@%+\-]+$'
}

# Test-FmTaskEndpoint: validate a task's endpoint record entirely from its
# durable metadata, BEFORE any runtime command or cleanup mutation. The
# validation binds the exact task id, backend, target, project, and worktree,
# so a lifecycle command can never be delivered to an endpoint that belongs to
# a different task.
#
# Returns a record with Valid, Backend, Target and Reason. Every refusal keeps
# the bash wording's meaning: preserve task state, refuse loudly, never guess.
#
# NOT PORTED: the zellij, orca, and cmux arms. This port ships one session
# provider (herdr); a meta naming another backend refuses by name rather than
# being validated against rules this port cannot enforce.
function Test-FmTaskEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MetaPath,
        [Parameter(Mandatory)][string]$TaskId
    )
    $fail = {
        param($Message)
        [pscustomobject]@{ Valid = $false; Backend = ''; Target = ''; Reason = $Message }
    }
    if (-not (Test-Path -LiteralPath $MetaPath -PathType Leaf)) {
        return & $fail "REFUSED: task $TaskId has no regular endpoint metadata at $MetaPath; preserving task state."
    }
    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        return & $fail 'REFUSED: task endpoint identity has an invalid task id; preserving task state.'
    }
    $window = Get-FmMetaExactValue -Path $MetaPath -Key 'window'
    if (-not $window) {
        return & $fail "REFUSED: task $TaskId has a missing, empty, or ambiguous window endpoint; preserving task state."
    }
    $worktree = Get-FmMetaExactValue -Path $MetaPath -Key 'worktree'
    if (-not $worktree) {
        return & $fail "REFUSED: task $TaskId has a missing, empty, or ambiguous worktree identity; preserving task state."
    }
    $project = Get-FmMetaExactValue -Path $MetaPath -Key 'project'
    if (-not $project) {
        return & $fail "REFUSED: task $TaskId has a missing, empty, or ambiguous project identity; preserving task state."
    }
    # A tab or carriage return inside an endpoint field is malformed metadata,
    # not a value to interpret: these fields are compared and re-emitted, and a
    # stray control character means the record was written by something other
    # than a spawn. (Embedded newlines cannot survive the line-based read.)
    if (($window + $worktree + $project) -match "[`t`r]") {
        return & $fail "REFUSED: task $TaskId has malformed endpoint metadata; preserving task state."
    }
    $backend = Get-FmMetaBackend -Path $MetaPath
    $binding = Get-FmMetaExactValue -Path $MetaPath -Key 'endpoint_task_id'
    if ($binding -and $binding -ne $TaskId) {
        return & $fail "REFUSED: endpoint metadata belongs to task $binding, not $TaskId; preserving task state."
    }

    switch ($backend) {
        'herdr' {
            if ($binding -ne $TaskId) {
                return & $fail "REFUSED: legacy Herdr endpoint metadata for task $TaskId lacks an exact task binding; preserving task state."
            }
            $session = Get-FmMetaExactValue -Path $MetaPath -Key 'herdr_session'
            $workspace = Get-FmMetaExactValue -Path $MetaPath -Key 'herdr_workspace_id'
            $tab = Get-FmMetaExactValue -Path $MetaPath -Key 'herdr_tab_id'
            $pane = Get-FmMetaExactValue -Path $MetaPath -Key 'herdr_pane_id'
            if (-not $session -or -not $workspace -or -not $tab -or -not $pane -or
                $window -ne "$session`:$pane" -or
                -not (Test-FmEndpointAtom -Value $session) -or
                -not (Test-FmEndpointAtom -Value $workspace) -or
                -not (Test-FmEndpointAtom -Value ($tab -replace ':', '_')) -or
                -not (Test-FmEndpointAtom -Value ($pane -replace ':', '_'))) {
                return & $fail "REFUSED: Herdr endpoint metadata for task $TaskId is malformed or inconsistent; preserving task state."
            }
        }
        'tmux' {
            $parts = $window -split ':', 2
            if ($parts.Count -ne 2 -or -not $parts[0] -or $parts[1] -ne "fm-$TaskId") {
                return & $fail "REFUSED: tmux endpoint '$window' is malformed or does not belong to task $TaskId; preserving task state."
            }
        }
        default {
            return & $fail "REFUSED: task $TaskId records backend '$backend', which this PowerShell port does not implement (it ships herdr; tmux records are validated but not driven); preserving task state."
        }
    }

    [pscustomobject]@{ Valid = $true; Backend = $backend; Target = $window; Reason = '' }
}

# Resolve-FmTaskSelector: resolve an fm-send/fm-peek style selector to a live
# backend target. Four forms, in order:
#   target containing ":"  used as-is - the escape hatch for an endpoint
#                          outside this firstmate home.
#   exact task id          routed through <state>/<id>.meta's recorded target.
#   "fm-<id>"              legacy task label, routed through <state>/<id>.meta.
#   anything else          refused. Unlike the bash tmux fallback there is no
#                          live-inventory window search here: a "successful"
#                          send to a guessed endpoint is worse than a loud
#                          failure, and the bash fallback exists only for
#                          tmux's ambient single server.
function Resolve-FmTaskSelector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Selector,
        [Parameter(Mandatory)][string]$StateDir
    )
    $none = {
        param($Message)
        [pscustomobject]@{
            Resolved = $false; Target = ''; Backend = ''; MetaPath = ''; TaskId = ''
            ExpectedLabel = ''; Harness = ''; Reason = $Message
        }
    }

    $taskId = ''
    if ($Selector -notmatch ':') {
        if (Test-Path -LiteralPath (Get-FmMetaPath -StateDir $StateDir -TaskId $Selector) -PathType Leaf) {
            $taskId = $Selector
        } elseif ($Selector.StartsWith('fm-')) {
            $candidate = $Selector.Substring(3)
            if (Test-Path -LiteralPath (Get-FmMetaPath -StateDir $StateDir -TaskId $candidate) -PathType Leaf) {
                $taskId = $candidate
            } else {
                return & $none "error: no metadata for $Selector in $StateDir; pass session:pane only when targeting an endpoint outside this firstmate home"
            }
        } else {
            return & $none "error: target '$Selector' is not resolvable (tried $StateDir/$Selector.meta). Use fm-$Selector for a recorded task, or pass a well-formed explicit backend target."
        }
    }

    if ($taskId) {
        $meta = Get-FmMetaPath -StateDir $StateDir -TaskId $taskId
        $target = Get-FmMetaTarget -Path $meta
        if (-not $target) {
            return & $none "error: no backend target recorded in $meta"
        }
        return [pscustomobject]@{
            Resolved      = $true
            Target        = $target
            Backend       = (Get-FmMetaBackend -Path $meta)
            MetaPath      = $meta
            TaskId        = $taskId
            ExpectedLabel = "fm-$taskId"
            Harness       = (Get-FmMetaValue -Path $meta -Key 'harness')
            Reason        = ''
        }
    }

    # An explicit backend target: accepted only when the endpoint can actually
    # be verified, so a typo cannot become a silent send into nothing.
    if (-not (Test-FmHerdrTargetExists -Target $Selector)) {
        return & $none "error: explicit target '$Selector' is not a live herdr endpoint. Use fm-<id> for a recorded task, or pass a target whose endpoint can be verified."
    }
    [pscustomobject]@{
        Resolved      = $true
        Target        = $Selector
        Backend       = 'herdr'
        MetaPath      = ''
        TaskId        = ''
        ExpectedLabel = ''
        Harness       = ''
        Reason        = ''
    }
}

# =============================================================================
# Control-plane capability tables
# (ported from bin/fm-control-lib.sh; see this file's header for the split)
#
# These are pure tables: no side effects, no backend command, no state read.
#
# The VERB ALLOWLIST itself is not here: bin/fm-control.ps1 is the control
# plane's only door on this port and states its closed list inline, so there is
# exactly one list rather than two that can drift. The list stays closed on
# purpose - there is no arbitrary-text and no generic raw-key entry point,
# because a routing-marked lifecycle command arrives as chat the agent reasons
# ABOUT instead of running.
# =============================================================================

# Get-FmControlHarnessFamily: the verified adapter a RECORDED harness value
# belongs to. A task launched from a raw command records that command's
# basename, which is why the adapters match by prefix. `pi` and `pi-signed` are
# exact because a `pi*` prefix would swallow the signed adapter. An
# unrecognized value returns '' rather than being guessed into a family.
function Get-FmControlHarnessFamily {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$RecordedHarness)
    if (-not $RecordedHarness) { return '' }
    switch -Regex ($RecordedHarness) {
        '^pi$'         { return 'pi' }
        '^pi-signed$'  { return 'pi-signed' }
        '^claude'      { return 'claude' }
        '^codex'       { return 'codex' }
        '^opencode'    { return 'opencode' }
        '^grok'        { return 'grok' }
        '^kimi'        { return 'kimi' }
        '^muse'        { return 'muse' }
        default        { return '' }
    }
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
function Get-FmControlInterruptKey {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Harness)
    switch ($Harness) {
        { $_ -in @('claude', 'codex', 'opencode', 'pi', 'pi-signed', 'kimi', 'muse') } { 'Escape' }
        'grok' { 'C-c' }
        default { '' }
    }
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
function Get-FmControlInterruptRepeat {
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Harness)
    if ($Harness -eq 'opencode') { return 2 }
    if ($Harness -in @('claude', 'codex', 'pi', 'pi-signed', 'grok', 'kimi', 'muse')) { return 1 }
    0
}

# The key that must follow the interrupt key to leave the composer empty.
# muse is the one verified adapter that RESTORES the cancelled prompt into its
# composer as real bright text, so an interrupt is not complete until Ctrl+U
# has cleared it - otherwise the next submitted line concatenates onto it.
function Get-FmControlInterruptClearKey {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Harness)
    if ($Harness -eq 'muse') { return 'C-u' }
    ''
}

# The command that exits the agent from its own composer.
function Get-FmControlExitCommand {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Harness)
    switch ($Harness) {
        { $_ -in @('claude', 'opencode', 'grok', 'kimi', 'muse') } { '/exit' }
        { $_ -in @('codex', 'pi', 'pi-signed') } { '/quit' }
        default { '' }
    }
}

# Which named keys a backend adapter can deliver.
function Test-FmControlBackendSupportsKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][string]$Key
    )
    switch ($Backend) {
        { $_ -in @('tmux', 'herdr', 'zellij', 'cmux') } { return ($Key -in @('Escape', 'Enter', 'C-c', 'C-u')) }
        'orca' { return ($Key -in @('Enter', 'C-c')) }
    }
    $false
}

# Whether <Backend> has a recovery-grade agent-state classifier. Without one,
# "the agent stopped" cannot be proven, and the control plane refuses a
# stop-proving verb rather than reporting an unproven transition as done.
function Test-FmControlBackendStateVerified {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Backend)
    $Backend -in @('tmux', 'herdr')
}

# Send-FmControlInterrupt: deliver the harness's verified interrupt sequence -
# the key the verified number of times, then the composer-clear key when the
# adapter needs one. Refuses BEFORE sending anything when the backend cannot
# deliver either key, because an interrupt that cancels the turn but leaves the
# restored prompt in the composer would make the next submitted line
# concatenate onto it.
#
# NOT PORTED: the muse session-log cancellation acknowledgement, which reads a
# busy-state source this area does not own. Delivery is reported as
# cancel=unconfirmed for every harness here, which is exactly what the bash
# control plane reports for every adapter except muse - never a claim that the
# turn was cancelled.
function Send-FmControlInterrupt {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Harness
    )
    $key = Get-FmControlInterruptKey -Harness $Harness
    $repeat = Get-FmControlInterruptRepeat -Harness $Harness
    $clear = Get-FmControlInterruptClearKey -Harness $Harness
    if (-not $key -or $repeat -lt 1) {
        throw "error: harness '$Harness' has no verified interrupt mechanics; refusing to guess an interrupt key"
    }
    if (-not (Test-FmControlBackendSupportsKey -Backend $Backend -Key $key)) {
        throw "error: harness $Harness interrupts with $key, which the $Backend backend cannot deliver; refusing to send a different key"
    }
    if ($clear -and -not (Test-FmControlBackendSupportsKey -Backend $Backend -Key $clear)) {
        throw ("error: harness $Harness needs $clear to clear its composer after an interrupt, which the $Backend backend " +
            'cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it')
    }
    for ($i = 0; $i -lt $repeat; $i++) {
        if (-not (Send-FmHerdrKey -Target $Target -Key $key)) {
            throw "error: interrupt key $key was not delivered to $Target on $Backend"
        }
        if ($i -lt ($repeat - 1)) { Start-Sleep -Seconds 0.2 }
    }
    if ($clear -and -not (Send-FmHerdrKey -Target $Target -Key $clear)) {
        throw ("error: interrupt key $key reached $Target, but $clear did not, so its composer still holds the cancelled " +
            'prompt; clear it before the next lifecycle action')
    }
    'unconfirmed'
}
