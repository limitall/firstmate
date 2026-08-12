#requires -Version 7.0
<#
    Public/FmBackendWindow.ps1 - the backend area's WINDOW contract: the generic
    per-endpoint reads the watcher's pane layer asks for, resolved against the
    task metadata and the one session provider this port drives.

    WHY THIS FILE EXISTS. The watcher (Public/FmWatch.ps1) is deliberately
    backend-agnostic: it asks for a recorded window list, a pane capture, a
    window kind, and a busy verdict by NAME, and skips its whole layer-1
    staleness backbone when those names are absent. The herdr adapter had landed
    with every underlying primitive - Get-FmHerdrCapture, Get-FmHerdrBusyState,
    Get-FmHerdrAgentState - under its own names, and nobody published the generic
    ones. The result was a silent, complete loss of pane-derived staleness: a
    dispatched crewmate could wedge and no wake would ever be raised for it,
    while every test stayed green. That is the same by-name binding hazard
    AGENTS.md describes, and this file is its other half.

    THIN, AND DELIBERATELY SO. Each function resolves the window's recorded
    backend and hands off. Nothing here re-implements a probe, and a backend this
    port does not drive is reported as unknown rather than guessed at - the same
    refuse-loudly-never-guess rule the rest of the backend area applies.

    PASSIVE. The watcher runs these every cycle, so a read here must never
    resurrect anything: the capture is gated on the read-only existence probe
    rather than the ready probe, which would start a stopped session server.

    Positional parameters are load-bearing. Every caller reaches these through
    Invoke-FmSeam, which splats an argument ARRAY - so the order below is the
    contract, not a convenience.
#>

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Every distinct endpoint recorded under a state directory, in task-id order.
.DESCRIPTION
Port of the watcher's recorded_windows(). Reads each state/<id>.meta's recorded
target and de-duplicates, so two tasks sharing an endpoint are walked once.
#>
function Get-FmRecordedWindows {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][string]$StatePath)

    # Emitted as an ordinary array, NOT with the unary-comma wrapper the
    # identity area uses: every caller here wraps the result in @(), and a
    # wrapped array would arrive nested one deep and read as a single item.
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $out = @()
    if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { return $out }
    foreach ($meta in @(Get-ChildItem -LiteralPath $StatePath -Filter '*.meta' -File -Force -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
        $target = ''
        try { $target = [string](Get-FmMetaTarget -Path $meta.FullName) } catch { $target = '' }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        if (-not $seen.Add($target)) { continue }
        $out += $target
    }
    return $out
}

<#
.SYNOPSIS
The state/<id>.meta whose recorded target is <Window>, or '' when none is.
#>
function Get-FmWindowMetaPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($Window)) { return '' }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { return '' }
    foreach ($meta in @(Get-ChildItem -LiteralPath $StatePath -Filter '*.meta' -File -Force -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
        $target = ''
        try { $target = [string](Get-FmMetaTarget -Path $meta.FullName) } catch { $target = '' }
        if ($target -eq $Window) { return $meta.FullName }
    }
    return ''
}

<#
.SYNOPSIS
The kind recorded for a window: ship, scout, secondmate - or 'unknown'.
.DESCRIPTION
Port of window_kind(). A meta with no kind= field defaults to ship, which is
what the bash original does; only a window with NO matching meta is unknown.
The distinction matters: the watcher treats a secondmate endpoint as healthy
when idle, and would wrongly surface one that read as unknown.
#>
function Get-FmWindowKind {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath
    )

    $meta = Get-FmWindowMetaPath -Window $Window -StatePath $StatePath
    if (-not $meta) { return 'unknown' }
    $kind = [string](Get-FmMetaValue -Path $meta -Key 'kind')
    if ([string]::IsNullOrWhiteSpace($kind)) { return 'ship' }
    return $kind
}

<#
.SYNOPSIS
The backend recorded for a window, defaulting to tmux exactly as the meta
compatibility contract does.
#>
function Get-FmWindowBackend {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath
    )

    $meta = Get-FmWindowMetaPath -Window $Window -StatePath $StatePath
    if (-not $meta) { return 'tmux' }
    return [string](Get-FmMetaBackend -Path $meta)
}

<#
.SYNOPSIS
The last <Lines> lines of a window's pane, or $null when it cannot be read.
.DESCRIPTION
$null means "no pane evidence", and the watcher skips that window's staleness
rather than treating an unreadable pane as a changed one. A backend this port
does not drive also reports $null: an unverified adapter must not be guessed at.
#>
function Get-FmBackendCapture {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath,
        [Parameter(Position = 2)][int]$Lines = 200
    )

    if ((Get-FmWindowBackend -Window $Window -StatePath $StatePath) -ne 'herdr') { return $null }
    # Existence, not readiness: readiness starts a stopped session server, and a
    # watcher poll must never resurrect an endpoint it is only observing.
    if (-not (Test-FmHerdrTargetExists -Target $Window)) { return $null }
    return (Get-FmHerdrCapture -Target $Window -Lines $Lines)
}

<#
.SYNOPSIS
True when a window's agent is positively working right now.
.DESCRIPTION
herdr reports semantic agent state natively, so the verdict comes from that
rather than from pane-tail regex. <Tail> is accepted because the watcher passes
the capture it already has, and is deliberately unused: the pane-shape
classifier is a separate fleet-wide owner that this port has not taken on, and
inventing a private copy of it here would put two answers on one question.

Anything other than a positive "working" reads as NOT busy, which is the loud
direction: it lets the pane go stale and be surfaced rather than suppressing a
wedged crewmate as busy.
#>
function Test-FmWindowBusy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Tail',
        Justification = 'Declared because the watcher passes the capture it already has, and deliberately unused: the pane-shape classifier is a separate fleet-wide owner this port has not taken on, and a private copy of it here would put two answers on one question. Dropping the parameter instead would make the seam call bind it into $args and vanish.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath,
        [Parameter(Position = 2)][AllowNull()][AllowEmptyString()][string]$Tail
    )

    if ((Get-FmWindowBackend -Window $Window -StatePath $StatePath) -ne 'herdr') { return $false }
    if (-not (Test-FmHerdrTargetExists -Target $Window)) { return $false }
    return ((Get-FmHerdrBusyState -Target $Window) -eq 'busy')
}

<#
.SYNOPSIS
The endpoint's busy verdict: "<busy|idle|dead|unknown> <source>".
.DESCRIPTION
The reader Get-FmCrewState asks for by name, and the reason `fm-crew-state.ps1`
answered "unknown - no backend state reader available" for every task in this
build. Port of fm_busy_classify_live, with the one deviation stated below.

The verdict's FIRST WORD is the contract; the whole string is the detail a
caller prints. `busy` asserts working, `idle` defers to the crew's own status
log, and anything else refuses to assert a state at all.

DEVIATION FROM BASH, DELIBERATE. The bash classifier prefers a busy-event
RECORD written by crewmate harness hooks and falls back to herdr's native state
for `busy` only, holding native `idle` back as "narrower than turn state". This
port installs no crewmate hooks (AGENTS.md section 14), so there is no record
layer to prefer and native state is the ONLY endpoint evidence that exists. It
is therefore also trusted for `idle` - which asserts nothing on its own, because
`idle` sends Get-FmCrewState to the crew's own status log rather than to a
verdict. Reporting `unknown` instead would leave every live crewmate's state
permanently unreadable, which is a worse answer than a deferred one.

A gone endpoint is `dead` before anything else is consulted: a crew whose pane
no longer exists is gone, whatever a stale log says.
#>
function Get-FmBackendBusyVerdict {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Id, Harness and StatePath are the busy-event RECORD layer''s inputs. That layer is not ported (AGENTS.md section 14), so they are unused here - but they are the owner''s published parameter list and every caller passes them by name, so removing one would make the by-name call throw and the caller would read that as "no owner at all".')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Backend,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$Target,
        [Parameter(Position = 2)][AllowNull()][AllowEmptyString()][string]$Id,
        [Parameter(Position = 3)][AllowNull()][AllowEmptyString()][string]$Harness,
        [Parameter(Position = 4)][AllowNull()][AllowEmptyString()][string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($Target)) { return 'unknown no-target' }
    if ($Backend -ne 'herdr') { return "unknown backend-unverified ($Backend)" }
    if (-not (Test-FmHerdrTargetExists -Target $Target)) { return 'dead endpoint-gone' }
    switch (Get-FmHerdrBusyState -Target $Target) {
        'busy' { 'busy herdr-native' }
        'idle' { 'idle herdr-native' }
        default { 'unknown herdr-native' }
    }
}

<#
.SYNOPSIS
alive, dead, or unknown for the agent registered at a window's endpoint.
.DESCRIPTION
Port of fm_backend_agent_alive: the recovery-grade agent state collapsed to the
three words the watcher's stale triage reads. Only 'dead' licenses a recovery
decision, so an unreadable or unported backend reports 'unknown'.
#>
function Get-FmBackendAgentAlive {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath
    )

    if ((Get-FmWindowBackend -Window $Window -StatePath $StatePath) -ne 'herdr') { return 'unknown' }
    switch (Get-FmHerdrAgentState -Target $Window) {
        'alive' { 'alive' }
        'dead' { 'dead' }
        'missing' { 'dead' }
        default { 'unknown' }
    }
}
