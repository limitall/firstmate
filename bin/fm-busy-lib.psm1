# fm-busy-lib.psm1 - the ONE owner of firstmate's semantic busy-state contract.
# Twin: bin/fm-busy-lib.sh
#
# Design source: the captain-approved semantic busy-state redesign
# (2026-07-28): each harness adapter reports turn lifecycle through a
# machine-readable semantic source it owns, classification always exposes
# which source produced it, and missing, malformed, stale, unsupported, or
# unverified semantic data is UNKNOWN - never idle. Endpoint death is the only
# process-level override and yields dead, never busy. Child processes, CPU,
# process sleep state, marker mtimes, and the old global UI-regex OR are not
# state signals here; state/<id>.turn-ended files remain wake NOTIFICATIONS
# owned by the watcher, not current-state truth.
#
# Wrong in either direction is expensive, which is why nothing below is
# "tidied": a false idle lets a send corrupt a running agent's composer
# mid-thought, and a false busy wedges supervision behind a worker that is
# actually waiting. Every rule the bash twin records was paid for; the reasoning
# is carried across, not just the code.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq is a strictly increasing integer per gen, advanced
# under the writer's lock, so an out-of-order apply can never regress a
# newer record.
#
# Semantic sources written by adapters (Get-FmBusySourcesForHarness owns the
# per-harness trust table; a record whose source is not trusted for the
# task's recorded harness classifies unknown, so one adapter's writer can
# never classify another adapter):
#   pi-ext           Pi/pi-signed per-task extension (agent_start/agent_settled)
#   opencode-plugin  OpenCode per-task plugin (session.status)
#   claude-hook      Claude lifecycle hooks (UserPromptSubmit/Stop/StopFailure/SessionEnd)
#   codex-hook, codex-appserver  reserved: Codex, gated by
#                    Test-FmBusyCodexSemanticSource
#   kimi-wire, kimi-hook  reserved: standalone Kimi, gated by Test-FmBusyKimiVerified
# Firstmate-owned sources accepted for every converted adapter:
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     a firstmate-controlled interruption of the worker
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, grok-regex, muse-session-log, missing,
#   malformed, gen-mismatch, source-mismatch, kimi-unverified,
#   codex-unverified, capture-failed, no-target
#
# Classification (Get-FmBusyClassification): busy | idle | unknown | dead,
# always with the producing source as the second token. Precedence:
#   1. dead endpoint (Get-FmBusyLiveClassification only) -> dead endpoint-gone
#   2. standalone Kimi before verification       -> unknown kimi-unverified
#   3. a valid, gen-matching, source-trusted record -> its state and source
#   4. no record at all: herdr's native busy verdict is trusted as busy
#      (generation state is sufficient for busy, not for idle), then the
#      muse session-log pull source, then the Grok-only temporary regex
#      fallback classifies a grok task from its rendered tail, then
#      unknown missing
#   5. malformed, stale, or untrusted records -> unknown, never a fallback
#
# The muse pull source is semantic, not rendered: it folds muse's own durable
# session event log. It has no writer, no arm, and no gen, because muse's
# default build ships no hook or plugin surface that could push events (its
# plugin engine reports "plugins are not available in this build" without
# MUSE_EXPERIMENTAL_PLUGINS). Nothing is armed for muse for the same reason
# standalone Kimi is not: a seeded record with no writer could never be cleared.
# See Get-FmBusyMuseRunState for the fold.
#
# The Grok arm is the ONLY rendered-text classification that survives the
# redesign, because Grok's structured lifecycle was not credited-live-verified
# in the approved audit; it is scoped to harness=grok and can never classify
# another adapter. The delivery guards in bin/fm-tmux-lib.sh match rendered
# footers for submit acknowledgement and away-mode supervisor injection only;
# neither is a recorded worker state source.
#
# Codex negotiation (Test-FmBusyCodexAppServerObservable,
# Test-FmBusyCodexHooksVerified): the approved contract prefers Codex's
# app-server turn lifecycle with capability negotiation, and sanctions its
# stable lifecycle hooks as the intermediate. Neither is usable on the
# installed binary, so Codex classifies unknown codex-unverified rather than
# falling back to idle, and fm-spawn installs no Codex busy wiring.
# docs/verification/supervision.md owns the evidence for both probes.
#
# ============================================================================
# THE fm-backend SEAM (docs/powershell-port-inventory.md R4) - READ THIS FIRST
# IF YOU ARE CONVERTING bin/fm-backend.sh.
# ============================================================================
# fm-busy-lib.sh has an UNDECLARED dependency on fm-backend.sh: it calls six
# fm_backend_*/fm_meta_* functions it never sources, relying on every caller
# having sourced both. bash tolerates that because a sourced function lands in
# the caller's one shell scope. A .psm1 resolves names in its OWN scope first,
# so an undeclared call would fail differently here - and fm-backend is a LATER
# wave, so there is nothing to Import-Module yet.
#
# Resolution: every one of those calls is a RUNTIME CAPABILITY PROBE
# (Get-FmBusyBackendCommand below), the exact PowerShell twin of the
# `command -v fm_backend_busy_state` guard the bash twin already uses for two
# of them. Verified on this host: Get-Command inside a .psm1 DOES find a
# function published in the importing session's scope, so a consumer that
# imports fm-backend.psm1 alongside this module gets the wired behavior with no
# import edge from here - the same shape bash has, without the module-scope
# trap.
#
# Wave 3 must revisit exactly this table. The probe looks for these names, in
# order, and expects these signatures; if the converted fm-backend.psm1 exports
# different names, EDIT $script:FmBusyBackendCommand rather than adding an
# import edge (this module must stay importable standalone):
#
#   bash                        probed PowerShell name        expected shape
#   --------------------------  ----------------------------  ------------------------------
#   fm_backend_target_exists    Test-FmBackendTargetExists    (backend, target, label) -> [bool]
#   fm_backend_busy_state       Get-FmBackendBusyState        (backend, target) -> 'busy'|'idle'|'unknown'
#   fm_backend_capture          Get-FmBackendCapture          (backend, target, lines) -> text
#                               Invoke-FmBackendCapture         (string, or lines joined with LF)
#   fm_backend_of_meta          Get-FmBackendOfMeta           (metaPath) -> backend token
#   fm_backend_target_of_meta   Get-FmBackendTargetOfMeta     (metaPath) -> target or ''
#   fm_meta_get                 Get-FmMetaValue               already in fm-common.psm1 - NO seam
#
# Two contract notes for whoever writes those exports. Each probed command is
# invoked POSITIONALLY with the full argument list shown above, because the bash
# twin passes all of them and a bash function ignores extras while a
# [CmdletBinding()] PowerShell function throws on them - so declare the trailing
# label/lines parameter even if the implementation ignores it. And
# Test-FmBackendTargetExists must return a real [bool]: any non-empty string is
# truthy in PowerShell, so returning the STRING 'False' would read as "the
# endpoint is alive".
#
# DEGRADATION WHEN THE PROBE MISSES is deliberately identical to the bash twin's
# behavior when fm-backend.sh was never sourced, because both worlds run against
# the same homes during the transition and a divergence here is a supervision
# bug, not a cosmetic one:
#
#   Get-FmBusyLiveClassification  a missing Test-FmBackendTargetExists yields
#                                 'dead endpoint-gone' - exactly what bash
#                                 produces, where `command not found` returns
#                                 127, the `if !` inverts it, and the 2>/dev/null
#                                 keeps it quiet. Silent here for the same reason.
#   Get-FmBusyMetaClassification  a missing Get-FmBackendOfMeta /
#                                 Get-FmBackendTargetOfMeta yields
#                                 'unknown no-target', because bash's empty
#                                 command substitutions leave target empty and
#                                 hit its own no-target arm. bash is NOT quiet
#                                 there (no redirect on those lines), so this
#                                 prints one stderr diagnostic naming the
#                                 capability - stdout stays byte-identical.
#   Get-FmBusyClassification      the herdr-native and Grok-capture arms are
#                                 already `command -v`-guarded in bash and keep
#                                 exactly that behavior: skip the native arm,
#                                 and report 'unknown capture-failed' for a grok
#                                 task with no pre-captured tail.
#
# An absent capability is SILENT on the live path (it is the expected wave-2
# state); a capability that is present but throws is LOUD, because that means a
# signature contract above was broken and a silent 'dead' verdict would tear
# down healthy work.
#
# ----------------------------------------------------------------------------
# Function mapping, so the pairing is greppable in both directions:
#
#   bash                                PowerShell                          exported
#   ----------------------------------  ----------------------------------  --------
#   fm_busy_kimi_verified               Test-FmBusyKimiVerified             yes
#   fm_busy_codex_appserver_observable  Test-FmBusyCodexAppServerObservable yes
#   fm_busy_codex_hooks_verified        Test-FmBusyCodexHooksVerified       yes
#   fm_busy_codex_semantic_source       Test-FmBusyCodexSemanticSource      yes
#   fm_busy_record_path                 Get-FmBusyRecordPath                yes
#   fm_busy_gen_path                    Get-FmBusyGenPath                   yes
#   fm_busy_token_valid                 Test-FmBusyToken                    yes
#   fm_busy_current_gen                 Get-FmBusyCurrentGen                yes
#   fm_busy_sources_for_harness         Get-FmBusySourcesForHarness         yes
#   fm_busy_source_trusted              Test-FmBusySourceTrusted            yes
#   fm_busy_record_read                 Read-FmBusyRecord                   yes
#   fm_busy_muse_binding_path           Get-FmBusyMuseBindingPath           yes
#   fm_busy_muse_cache_path             Get-FmBusyMuseCachePath             yes
#   fm_busy_muse_binding_field          Get-FmBusyMuseBindingField          yes
#   fm_busy_muse_cache_field            Get-FmBusyMuseCacheField            yes
#   fm_busy_muse_binding_has_prior_log  Test-FmBusyMuseBindingHasPriorLog   yes
#   fm_busy_muse_main_log_path_valid    Test-FmBusyMuseMainLogPathValid     yes
#   fm_busy_muse_matching_logs          Get-FmBusyMuseMatchingLogs          yes
#   fm_busy_muse_namespace_day          Get-FmBusyMuseNamespaceDay          yes
#   fm_busy_muse_namespace_signature    Get-FmBusyMuseNamespaceSignature    yes
#   fm_busy_muse_cached_session_log     Get-FmBusyMuseCachedSessionLog      yes
#   fm_busy_muse_cache_session_log      Write-FmBusyMuseSessionLogCache     yes
#   fm_busy_muse_session_log            Get-FmBusyMuseSessionLog            yes
#   fm_busy_muse_run_events             Get-FmBusyMuseRunEvents             yes
#   fm_busy_muse_run_state              Get-FmBusyMuseRunState              yes
#   fm_busy_muse_active_run_id          Get-FmBusyMuseActiveRunId           yes
#   fm_busy_muse_run_terminal           Get-FmBusyMuseRunTerminal           yes
#   (none)                              Get-FmBusyPosixCksum                no (cksum core)
#   (none)                              Get-FmBusyCksumText                 no (cksum core)
#   fm_busy_grok_tail_busy              Test-FmBusyGrokTail                 yes
#   fm_busy_classify                    Get-FmBusyClassification            yes
#   fm_busy_classify_live               Get-FmBusyLiveClassification        yes
#   fm_busy_classify_meta               Get-FmBusyMetaClassification        yes
#   fm_busy_is_busy                     Test-FmBusy                         yes
#   FM_BUSY_LIB_VERSION                 Get-FmBusyLibVersion                yes
#   FM_BUSY_KIMI_VERIFIED_VERSIONS      $script:FmBusyKimiVerifiedVersions  no (gate data)
#   (none)                              Get-FmBusyBackendCommand            no (the R4 probe)
#   (none)                              Get-FmBusySingleLine                no (bash `read` twin)
#
# BASH CONTORTIONS THAT DISAPPEAR HERE, and the one that must NOT:
#
#   bash contortion                     why it existed              replaced by
#   ----------------------------------  --------------------------  ----------------------------
#   fm_busy_record_read prints the       a bash function has ONE     one hashtable carrying Ok
#   FAILURE REASON on stdout             return channel, so the      plus either the four fields
#   ("missing"/"malformed"/              reason had to ride the      or Reason - no caller has to
#   "gen-mismatch") where success        same channel as the data    know that "missing" is a
#   prints four fields                                               reason and not a state
#   fm_busy_source_trusted's             bash cannot return an       a [string[]] and -ccontains
#   `case " $trusted " in *" $2 "*`      array from a function, so
#   space-fencing                        membership was substring
#                                        matching on a padded string
#   `read -r -a` (not `set --`)          to avoid glob-expanding a   .Split(' ', RemoveEmptyEntries)
#   to split the record line             field and to avoid          on a plain string, which has
#                                        clobbering the CALLER's     no globbing and no caller
#                                        positional parameters       state to clobber at all
#   grep -v | tail -12 | grep -qiE       three processes per         one in-process filter and one
#   for the Grok tail                    classification              Regex.IsMatch
#
#   KEPT DELIBERATELY: the exact `read` semantics. bash's
#   `IFS= read -r gen < f` FAILS at EOF-without-newline, and the twin's
#   `|| gen=` then BLANKS the partial value - so a gen sidecar with no
#   trailing LF reads as "never armed", and a record with no trailing LF reads
#   as malformed. Get-FmBusySingleLine reproduces that exactly (verified
#   against bash on this host) instead of "helpfully" accepting an unterminated
#   final line. CR is likewise NOT stripped anywhere in this module: bash `read
#   -r` keeps it, so a CRLF record must classify malformed in BOTH worlds - on
#   Windows that is a live hazard, not a theoretical one.
#
# WHAT THIS MODULE NEVER DOES. It never probes process state, never reads a
# marker mtime, and never matches rendered text for any harness but grok. Those
# are not omissions to be filled in later; they are the redesign.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it: a .psm1
# resolves function names in its OWN scope (docs/powershell-port-inventory.md
# R4). fm-common is a FOUNDATION dependency and always exists; the fm-backend
# calls above are the seam that cannot be an import yet.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmBusyLibVersion = 'v1'

# Standalone-Kimi verification gate. Empty means no installed Kimi version
# has passed live verification, so every standalone Kimi task classifies
# unknown kimi-unverified and fm-spawn wires no Kimi busy events. Kimi's
# rendered moon-phase spinner is deliberately NOT a state source here: the
# approved redesign forbids inventing a Kimi UI signature, and that spinner
# is locale- and emoji-font-sensitive.
#
# Preferred source, in order: Wire mode's JSON-RPC `prompt` request lifetime,
# whose outstanding request exactly brackets a turn and returns finished,
# cancelled, or max_steps_reached (so it covers interruption, which `Stop`
# does not); then the documented lifecycle hooks, which must include
# `Interrupt` because Kimi documents that `Stop` does not fire on interrupts.
#
# To open the gate: install Kimi, live-verify the chosen source brackets a
# real turn on a firstmate-launched worker including the interrupt path,
# record the version, exact commands, and observed output in
# docs/verification/supervision.md, add the verified version string(s) here,
# and land the wiring in fm-spawn behind this same gate in the same change.
# Keep this in step with FM_BUSY_KIMI_VERIFIED_VERSIONS in the bash twin: both
# worlds read the same homes, so a gate that opens on one side only would let
# one classify a task the other refuses to.
$script:FmBusyKimiVerifiedVersions = ''

# The fm-backend seam's probe table. See the header. Each entry is an ordered
# candidate list; the first name that resolves in ANY visible scope wins.
$script:FmBusyBackendCommand = @{
    TargetExists = @('Test-FmBackendTargetExists')
    BusyState    = @('Get-FmBackendBusyState')
    Capture      = @('Get-FmBackendCapture', 'Invoke-FmBackendCapture')
    MetaBackend  = @('Get-FmBackendOfMeta')
    MetaTarget   = @('Get-FmBackendTargetOfMeta')
}

# Get-FmBusyBackendCommand: the `command -v fm_backend_*` twin.
#
# Resolved on EVERY call rather than memoized, deliberately. The bash twin
# re-evaluates `command -v` each time too, and a consumer may import
# fm-backend.psm1 after this module (verified: a function published later is
# still found), so caching the first miss would permanently disable the wired
# path for that process.
#
# CommandType is pinned so a stray executable or alias of the same name on PATH
# can never be invoked in place of the backend function this asks for.
function Get-FmBusyBackendCommand {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('TargetExists', 'BusyState', 'Capture', 'MetaBackend', 'MetaTarget')]
        [string]$Capability
    )

    foreach ($name in $script:FmBusyBackendCommand[$Capability]) {
        $found = @(Get-Command -Name $name -CommandType Function, Cmdlet, Filter -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { return $found[0] }
    }
    return $null
}

# Get-FmBusySingleLine: the twin of bash's
#   { IFS= read -r line && ! IFS= read -r extra; } < "$f"
# and, for a one-line sidecar, of `IFS= read -r gen < "$f" || gen=`.
#
# Returns the single line WITHOUT its terminator, or $null when the file does
# not hold exactly one LF-terminated line. All four bash outcomes verified on
# this host and reproduced here:
#   "one\n"        -> "one"   (read ok, second read hits EOF)
#   "one\ntwo\n"   -> $null   (the second read SUCCEEDS, so `! read` is false)
#   "one"          -> $null   (read returns non-zero at EOF; the caller's
#                              `|| gen=` then discards the partial value)
#   ""             -> $null
# CR is left in the value on purpose - `read -r` keeps it, so a CRLF file is
# malformed in both worlds rather than silently accepted on Windows only.
function Get-FmBusySingleLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return $null }
    $text = ''
    try {
        $text = [System.IO.File]::ReadAllText($native)
    } catch {
        # Unreadable is indistinguishable from absent for every caller here,
        # exactly as bash's `2>/dev/null` redirect makes it.
        return $null
    }
    $idx = $text.IndexOf("`n")
    if ($idx -lt 0) { return $null }
    if ($idx -lt ($text.Length - 1)) { return $null }
    return $text.Substring(0, $idx)
}

<#
.SYNOPSIS
The record-format version token this module reads and writes.
.DESCRIPTION
Twin of FM_BUSY_LIB_VERSION. Exported because the writer (bin/fm-busy-event.sh,
whose PowerShell twin lands in wave 4) must emit the same leading token that
Read-FmBusyRecord requires, and a second literal would be a silent format fork.
#>
function Get-FmBusyLibVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmBusyLibVersion
}

<#
.SYNOPSIS
True once an installed standalone Kimi version has passed live verification.
.DESCRIPTION
Twin of fm_busy_kimi_verified. Empty gate data means every standalone Kimi task
classifies unknown kimi-unverified; see $script:FmBusyKimiVerifiedVersions above
for what opening the gate requires.
#>
function Test-FmBusyKimiVerified {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return -not [string]::IsNullOrEmpty($script:FmBusyKimiVerifiedVersions)
}

<#
.SYNOPSIS
Capability negotiation for the Codex app-server turn lifecycle.
.DESCRIPTION
Twin of fm_busy_codex_appserver_observable. True only when a pane worker's turns
are observable through the app-server protocol on the installed binary.
codex-cli 0.145.0 verdict (live, 2026-07-28): NOT observable. The v2 protocol
does define the needed turn lifecycle (turn/started plus a turn/completed status
of completed, interrupted, failed, or inProgress), but an interactive TUI worker
neither starts nor attaches to the app-server daemon, and `codex app-server
daemon start` refuses outside the managed standalone install, so no client can
observe a pane worker's turns.
#>
function Test-FmBusyCodexAppServerObservable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $false
}

<#
.SYNOPSIS
True once Codex's stable lifecycle hooks are live-verified for a firstmate worker.
.DESCRIPTION
Twin of fm_busy_codex_hooks_verified - the sanctioned intermediate (UserPromptSubmit
to open a turn, Stop and SessionEnd to close it). codex-cli 0.145.0 verdict (live,
2026-07-28): NOT verified. Firstmate-written project hooks under <worktree>/.codex/
never fired in an interactive pane whose directory trust was granted, nor under
`codex exec`, in either case with --dangerously-bypass-hook-trust, while global
hooks fired in the same runs. Codex additionally exposes no StopFailure hook, so
an API-error turn end would need separate coverage even after the discovery
problem is solved.
#>
function Test-FmBusyCodexHooksVerified {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $false
}

<#
.SYNOPSIS
True when ANY verified Codex semantic source exists.
.DESCRIPTION
Twin of fm_busy_codex_semantic_source. fm-spawn arms and wires Codex only behind
this gate, and the classifier reports unknown codex-unverified until it opens.
#>
function Test-FmBusyCodexSemanticSource {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Test-FmBusyCodexAppServerObservable) -or (Test-FmBusyCodexHooksVerified))
}

<#
.SYNOPSIS
The path of a task's busy-state record.
.DESCRIPTION
Twin of fm_busy_record_path. Composed with '/' rather than Join-Path so the
string is byte-identical to the bash twin's for the same inputs: these paths are
compared and logged across the two worlds, and the file helpers convert to
native form at the point of IO anyway.
#>
function Get-FmBusyRecordPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )
    return "$StateDir/$Id.busy-state"
}

<#
.SYNOPSIS
The path of a task's busy-state generation sidecar.
.DESCRIPTION
Twin of fm_busy_gen_path. Same string discipline as Get-FmBusyRecordPath.
#>
function Get-FmBusyGenPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )
    return "$StateDir/$Id.busy-gen"
}

<#
.SYNOPSIS
The conservative token charset shared by the gen, source, and event fields.
.DESCRIPTION
Twin of fm_busy_token_valid: `case "$1" in ''|*[!A-Za-z0-9._-]*) return 1`.
Anything else is malformed.

The anchors are \A and \z, not ^ and $, because .NET's $ ALSO matches before a
trailing newline - so '^[A-Za-z0-9._-]+$' would accept "g1.2.3`n", which the
bash character-class test rejects. That single character is the difference
between rejecting a corrupt record and trusting it.
#>
function Test-FmBusyToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Value = '')

    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return ($Value -cmatch '\A[A-Za-z0-9._-]+\z')
}

<#
.SYNOPSIS
The task's armed generation token, or $null when the contract was never armed.
.DESCRIPTION
Twin of fm_busy_current_gen. $null is the bash non-zero return; a value is the
bash zero return, so a caller tests `if ($null -eq $gen)` exactly where its bash
twin tests `|| return 1`.

A sidecar whose single line is not a valid token - including one with no
trailing LF, which bash's `read || gen=` discards outright - reads as NEVER
ARMED rather than as a corrupt gen. That distinction is load-bearing: an unarmed
task with a record classifies malformed, and only a gen that PARSES can produce
gen-mismatch.
#>
function Get-FmBusyCurrentGen {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )

    $gen = Get-FmBusySingleLine (Get-FmBusyGenPath $StateDir $Id)
    if ($null -eq $gen) { return $null }
    if (-not (Test-FmBusyToken $gen)) { return $null }
    return $gen
}

<#
.SYNOPSIS
The semantic sources trusted to classify a task recorded with <Harness>.
.DESCRIPTION
Twin of fm_busy_sources_for_harness, returning a [string[]] where bash returned
one space-separated line; the bash twin's space-fenced substring match exists
only because a bash function cannot return an array. Possibly empty - a harness
with no verified semantic writer trusts NOTHING, which is what makes an
untrusted record classify unknown instead of falling back.

The firstmate-owned sources (fm-spawn, fm-interrupt, fm-recovery) are appended
for every converted adapter. Grok and muse deliberately trust nothing: neither
has a semantic WRITER, so neither is armed, and both read their live source on
demand in the classifier (grok's rendered tail, muse's session log) rather than
through a stored record. Listing a source here without a writer that can clear it
would seed a busy record nothing could ever settle.

Every harness comparison is CASE-SENSITIVE (-clike / -ceq), matching bash `case`,
which PowerShell's default case-insensitive operators would silently widen. Note
`pi` and `pi-signed` are EXACT matches, not a `pi*` prefix.

CALL IT AS `@(Get-FmBusySourcesForHarness $h)`. The result is emitted UNROLLED
so that idiom is correct and an empty result is an empty array rather than
$null. The alternative spelling - returning the array intact with `,$array` /
-NoEnumerate - is WRONG for this function: `@()` around it nests the array one
level deep, and every membership test then silently answers false (verified on
this host while writing it, which is why the trap is recorded here rather than
left for the next reader).
#>
function Get-FmBusySourcesForHarness {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural matches the return shape: this yields the whole trusted-source SET for one harness, and a singular name would read as get-one-source. Membership is asked separately through Test-FmBusySourceTrusted.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Harness = '')

    $empty = [string[]]@()
    $adapter = $null
    if ($Harness -clike 'claude*') {
        $adapter = @('claude-hook')
    } elseif ($Harness -clike 'codex*') {
        if (-not (Test-FmBusyCodexSemanticSource)) { return $empty }
        $adapter = @('codex-hook', 'codex-appserver')
    } elseif ($Harness -clike 'opencode*') {
        $adapter = @('opencode-plugin')
    } elseif ($Harness -ceq 'pi' -or $Harness -ceq 'pi-signed') {
        $adapter = @('pi-ext')
    } elseif ($Harness -clike 'kimi*') {
        if (-not (Test-FmBusyKimiVerified)) { return $empty }
        $adapter = @('kimi-wire', 'kimi-hook')
    } else {
        return $empty
    }

    return [string[]]($adapter + @('fm-spawn', 'fm-interrupt', 'fm-recovery'))
}

<#
.SYNOPSIS
True when <Source> is trusted to classify a task recorded with <Harness>.
.DESCRIPTION
Twin of fm_busy_source_trusted. -ccontains, because source tokens are
case-sensitive in the record and PowerShell's default -contains is not.
#>
function Test-FmBusySourceTrusted {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Harness = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Source = ''
    )

    if ([string]::IsNullOrEmpty($Source)) { return $false }
    return (@(Get-FmBusySourcesForHarness $Harness) -ccontains $Source)
}

<#
.SYNOPSIS
Parse and validate state/<id>.busy-state against the armed generation.
.DESCRIPTION
Twin of fm_busy_record_read. Returns a hashtable, always with the same keys:

  Ok      $true for a valid, gen-matching record
  State   busy|idle|unknown        (Ok only)
  Source  the writing source token (Ok only)
  Event   the event token          (Ok only)
  Seq     the raw seq field as a STRING, so a caller sees the exact recorded
          token rather than a reparsed number
  Reason  '' when Ok, else one of:
            missing       no record file
            malformed     unparseable line, bad tokens, or a record with no
                          armed gen to bind to
            gen-mismatch  a record from a stale incarnation

The bash twin prints the reason on stdout where success prints four fields,
because a bash function has one return channel. Every consequence of that
squeeze is gone here, but the VALUES are identical, so a differential test can
compare `Reason` against the bash stdout token directly.

Parsing notes that are contract, not implementation:
  - the record must be EXACTLY one LF-terminated line (see Get-FmBusySingleLine)
  - fields split on runs of spaces with leading/trailing ignored, matching
    `IFS=' ' read -r -a` - and, like `read -a`, without globbing, so a record
    carrying `source=*` is REJECTED rather than expanded against the cwd
  - an unrecognized `key=` field, or a field with no recognized prefix at all,
    is malformed; a repeated key takes the LAST occurrence, as the bash loop does
  - a missing key leaves its value empty and therefore fails validation, so a
    truncated record can never validate on the fields that survived
#>
function Read-FmBusyRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )

    $bad = {
        param([string]$Reason)
        @{ Ok = $false; State = ''; Source = ''; Event = ''; Seq = ''; Reason = $Reason }
    }

    $recordPath = Get-FmBusyRecordPath $StateDir $Id
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $recordPath))) {
        return (& $bad 'missing')
    }

    # A record without an armed gen has no incarnation to bind to.
    $gen = Get-FmBusyCurrentGen $StateDir $Id
    if ($null -eq $gen) { return (& $bad 'malformed') }

    $line = Get-FmBusySingleLine $recordPath
    if ($null -eq $line) { return (& $bad 'malformed') }

    $fields = $line.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($fields.Length -lt 1) { return (& $bad 'malformed') }
    if ($fields[0] -cne $script:FmBusyLibVersion) { return (& $bad 'malformed') }

    $rGen = ''; $rSeq = ''; $rState = ''; $rSource = ''; $rEvent = ''; $rTs = ''
    for ($i = 1; $i -lt $fields.Length; $i++) {
        $f = $fields[$i]
        if ($f.StartsWith('gen=')) { $rGen = $f.Substring(4) }
        elseif ($f.StartsWith('seq=')) { $rSeq = $f.Substring(4) }
        elseif ($f.StartsWith('state=')) { $rState = $f.Substring(6) }
        elseif ($f.StartsWith('source=')) { $rSource = $f.Substring(7) }
        elseif ($f.StartsWith('event=')) { $rEvent = $f.Substring(6) }
        elseif ($f.StartsWith('ts=')) { $rTs = $f.Substring(3) }
        else { return (& $bad 'malformed') }
    }

    if (-not (Test-FmBusyToken $rGen)) { return (& $bad 'malformed') }
    if (-not (Test-FmBusyToken $rSource)) { return (& $bad 'malformed') }
    if (-not (Test-FmBusyToken $rEvent)) { return (& $bad 'malformed') }
    if ($rSeq -cnotmatch '\A[0-9]+\z') { return (& $bad 'malformed') }
    if ($rTs -cnotmatch '\A[0-9]+\z') { return (& $bad 'malformed') }
    if ($rState -cne 'busy' -and $rState -cne 'idle' -and $rState -cne 'unknown') {
        return (& $bad 'malformed')
    }
    if ($rGen -cne $gen) { return (& $bad 'gen-mismatch') }

    return @{ Ok = $true; State = $rState; Source = $rSource; Event = $rEvent; Seq = $rSeq; Reason = '' }
}

# ============================================================================
# muse session-log busy source
# ============================================================================
#
# muse persists an append-only session event log per session at
# <sessions-root>/YYYY/MM/DD/<session-uuid>/session.jsonl, and brackets every
# submitted turn with one run lifecycle pair. Verified live on muse
# 0.1.0-R708.1 across completed, interrupted, and killed-mid-turn turns:
#   {"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started",...
#   {"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"terminal",
#     "terminal":"completed"|"cancelled",...
# An Escape interrupt closes its run with terminal=cancelled, so unlike Claude's
# Stop hook this source covers the interrupt path itself. Any later
# run_retracted records follow the terminal rather than replacing it.
#
# Both halves of the fold are trusted. An open run is positive proof a turn is
# in flight, and a settled log is idle: the credentialed multi-step smoke showed
# one run pair spans a whole multi-step turn, including an Escape interrupt that
# closes the run with terminal=cancelled instead of continuing the turn in
# another run. This gives the settled log the same idle trust as the Claude and
# Pi push sources. A version allowlist would be false precision and a maintenance
# treadmill for an auto-updating vendor binary: busy classification receives only
# the normalized muse harness identity, while session metadata records semver
# 0.1.0 plus a build SHA that cannot be matched against it. Resolution failures -
# no sidecar, no matching log, an unreadable or run-free log - remain unknown
# because those prove nothing about the turn either way. See
# docs/verification/muse.md for the evidence.
#
# ----------------------------------------------------------------------------
# THE THREE THINGS THIS CONVERSION HAD TO GET EXACTLY RIGHT
#
# 1. THE NAMESPACE SIGNATURE IS CROSS-LANGUAGE DURABLE STATE. The resolution
#    cache state/<id>.muse-session-current records a POSIX `cksum` of the day
#    directory's manifest, and a cache written by the bash twin must validate
#    here (and vice versa) because both trees read the same home - contract 2 in
#    docs/powershell-port.md. So Get-FmBusyPosixCksum is a real CRC-32/CKSUM
#    (poly 0x04C11DB7, unreflected, length-suffixed, final complement), NOT
#    .NET's zlib CRC32 and not a hash of convenience. Getting this subtly wrong
#    would not fail loudly; it would silently invalidate every cache the other
#    language wrote, re-scanning the whole namespace on every classification.
#
# 2. THE NODE HELPER IS ABSORBED, AND THAT IS THE ONE DELIBERATE DIVERGENCE.
#    fm_busy_muse_matching_logs shells out to an inline `node` script to scan the
#    session namespace, and guards it with `command -v node || return 1`. This
#    twin does the scan in-process (docs/powershell-port.md: helper interpreters
#    are absorbed natively), so on a host with NO node installed bash resolves no
#    candidates and classifies `unknown muse-session-log` while this resolves
#    normally. Every other input produces the same answer. The divergence is in
#    the safe direction - a real semantic fold instead of a tooling-shaped
#    unknown - and it is recorded rather than hidden because a differential run
#    on a node-less host will see it.
#
# 3. PATHS KEEP THE ROOT'S OWN SPELLING, JOINED WITH '/'. The bash twin's
#    resolution turns on STRING prefix arithmetic (Test-FmBusyMuseMainLogPathValid
#    strips `$root/` off the front and splits the remainder), and the sidecar's
#    prior_log= lines are compared for exact string equality. So every composed
#    path here is `<parent>/<child>` against the caller's own root spelling, and
#    only the filesystem calls go through ConvertTo-FmNativePath. node's
#    path.join would emit backslashes on Windows and break exactly that
#    arithmetic.

# `${s%%/*}` - everything before the first '/', or the whole string when there
# is none. Paired with Get-FmBusyMuseTail below to reproduce bash's path split
# arm for arm, INCLUDING its degenerate behaviour on a short path (where both
# yield the whole remaining string, which then fails the leaf check).
function Get-FmBusyMuseHead {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')
    $i = $Text.IndexOf('/')
    if ($i -lt 0) { return $Text }
    return $Text.Substring(0, $i)
}

# `${s#*/}` - everything after the first '/', or the whole string when there is
# none.
function Get-FmBusyMuseTail {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')
    $i = $Text.IndexOf('/')
    if ($i -lt 0) { return $Text }
    return $Text.Substring($i + 1)
}

# A 32-bit mask and a top-bit probe, as INT64 literals. The `L` suffix is
# load-bearing and cost real debugging time: PowerShell parses the bare literal
# `0xFFFFFFFF` as [int] -1, so `$uint64 -band 0xFFFFFFFF` widens -1 back to
# 0xFFFFFFFFFFFFFFFF and masks NOTHING - the CRC then silently exceeds 32 bits
# and the [uint32] cast below throws. Same trap for `0x80000000`, which parses as
# [int]::MinValue. Never spell either of these without the suffix.
$script:FmBusyCksumMask = 0xFFFFFFFFL
$script:FmBusyCksumTopBit = 0x80000000L

# The CRC-32/CKSUM table. Built once at import: 256 entries is cheap, and every
# namespace signature walks it once per byte of every first line in the day.
$script:FmBusyCksumTable = $(
    $table = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        $c = ([uint64]$i) -shl 24
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band $script:FmBusyCksumTopBit) -ne 0) {
                $c = (($c -shl 1) -bxor 0x04C11DB7) -band $script:FmBusyCksumMask
            } else {
                $c = ($c -shl 1) -band $script:FmBusyCksumMask
            }
        }
        $table[$i] = [uint32]$c
    }
    , $table
)

<#
.SYNOPSIS
POSIX `cksum` of a byte sequence, formatted as awk renders it: "<crc>:<bytes>".
.DESCRIPTION
The bash twin computes `printf '%s' "$text" | cksum | awk '{ print $1 ":" $2 }'`.
That is CRC-32/CKSUM: polynomial 0x04C11DB7, init 0, NO input or output
reflection, the byte LENGTH appended low-octet-first, and a final one's
complement. It is NOT the reflected zlib CRC32 that most libraries mean by
"CRC32", so it is implemented rather than delegated - see note 1 in the section
header for why an approximation here would be silently expensive.
#>
function Get-FmBusyPosixCksum {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][byte[]]$Bytes = $null)

    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $table = $script:FmBusyCksumTable
    $mask = $script:FmBusyCksumMask
    $crc = [uint64]0
    foreach ($b in $Bytes) {
        $idx = [int](((($crc -shr 24) -band 0xFF) -bxor $b) -band 0xFF)
        $crc = ((($crc -shl 8) -band $mask) -bxor $table[$idx])
    }
    # The LENGTH is folded in one octet at a time, low octet first - the step
    # that makes this cksum rather than a plain CRC-32, and the reason two files
    # differing only in trailing NULs still get different signatures.
    $len = [uint64]$Bytes.Length
    while ($len -ne 0) {
        $idx = [int](((($crc -shr 24) -band 0xFF) -bxor ($len -band 0xFF)) -band 0xFF)
        $crc = ((($crc -shl 8) -band $mask) -bxor $table[$idx])
        $len = $len -shr 8
    }
    $crc = (-bnot $crc) -band $mask
    return ('{0}:{1}' -f $crc, $Bytes.Length)
}

# The exact bytes bash hands `cksum`: UTF-8, no BOM, no added terminator.
function Get-FmBusyCksumText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ($null -eq $Text) { $Text = '' }
    return (Get-FmBusyPosixCksum ([System.Text.UTF8Encoding]::new($false).GetBytes($Text)))
}

<#
.SYNOPSIS
The per-task sidecar fm-spawn writes to bind a pane to its session log.
.DESCRIPTION
Twin of fm_busy_muse_binding_path. The sidecar records sessions_root=<abs>,
workspace_root=<abs>, one binding_id=<token>, and one prior_log=<abs> for each
matching main log that predates this pane - so the classifier never has to
re-derive muse's data directory.
#>
function Get-FmBusyMuseBindingPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )
    return ('{0}/{1}.muse-session' -f $StateDir, $Id)
}

<#
.SYNOPSIS
The per-task session-log resolution cache.
.DESCRIPTION
Twin of fm_busy_muse_cache_path.
#>
function Get-FmBusyMuseCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )
    return ('{0}/{1}.muse-session-current' -f $StateDir, $Id)
}

# The shared `key=`-prefixed field read used by both sidecars: FIRST matching
# line wins, an EMPTY value is a failure (bash's `[ -n "$line" ] || return 1`),
# and an absent file or absent key yields $null.
function Get-FmBusyMuseKeyedField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Path = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Key = ''
    )

    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) { return $null }
    $prefix = $Key + '='
    foreach ($line in (Get-FmFileLines $Path)) {
        if (-not $line.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        $value = $line.Substring($prefix.Length)
        if ([string]::IsNullOrEmpty($value)) { return $null }
        return $value
    }
    return $null
}

<#
.SYNOPSIS
Read one field from the per-task binding sidecar, or $null.
.DESCRIPTION
Twin of fm_busy_muse_binding_field. $null is bash's nonzero return.
#>
function Get-FmBusyMuseBindingField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Key = ''
    )
    return (Get-FmBusyMuseKeyedField (Get-FmBusyMuseBindingPath $StateDir $Id) $Key)
}

<#
.SYNOPSIS
Read one field from the resolution cache, or $null.
.DESCRIPTION
Twin of fm_busy_muse_cache_field.
#>
function Get-FmBusyMuseCacheField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Key = ''
    )
    return (Get-FmBusyMuseKeyedField (Get-FmBusyMuseCachePath $StateDir $Id) $Key)
}

<#
.SYNOPSIS
Does the binding sidecar already list <SessionLog> as pre-existing?
.DESCRIPTION
Twin of fm_busy_muse_binding_has_prior_log: an exact whole-line match against
`prior_log=<path>`. A log the sidecar recorded at spawn time predates this pane
and can never be its own session.
#>
function Test-FmBusyMuseBindingHasPriorLog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$SessionLog = ''
    )

    $path = Get-FmBusyMuseBindingPath $StateDir $Id
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $path))) { return $false }
    $wanted = 'prior_log=' + $SessionLog
    foreach ($line in (Get-FmFileLines $path)) {
        if ([string]::Equals($line, $wanted, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Is <SessionLog> a MAIN session log directly under <SessionsRoot>?
.DESCRIPTION
Twin of fm_busy_muse_main_log_path_valid. The shape is
<root>/YYYY/MM/DD/<session>/session.jsonl with every component non-empty, which
is exactly what excludes muse's own native sub-agent logs one directory deeper
under subagent/<child-session-id>/session.jsonl - they carry an INDEPENDENT run
lifecycle, so folding one would report the parent busy long after the parent's
turn ended.

A SYMLINK is refused even when it points at a real log, matching the twin's
`[ -f "$log" ] && [ ! -L "$log" ]`.
#>
function Test-FmBusyMuseMainLogPathValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$SessionsRoot = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$SessionLog = ''
    )

    # `${1%/}` then the `//` -> `/` collapse loop, in that order.
    $root = $SessionsRoot
    if ($root.EndsWith('/', [System.StringComparison]::Ordinal)) {
        $root = $root.Substring(0, $root.Length - 1)
    }
    while ($root.Contains('//', [System.StringComparison]::Ordinal)) {
        $root = $root.Replace('//', '/')
    }
    if ([string]::IsNullOrEmpty($root)) { return $false }
    $native = ConvertTo-FmNativePath $SessionLog
    if (-not [System.IO.File]::Exists($native)) { return $false }
    if (Test-FmSymlink $SessionLog) { return $false }

    $prefix = $root + '/'
    if (-not $SessionLog.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $false }
    $rel = $SessionLog.Substring($prefix.Length)

    $year = Get-FmBusyMuseHead $rel; $rel = Get-FmBusyMuseTail $rel
    $month = Get-FmBusyMuseHead $rel; $rel = Get-FmBusyMuseTail $rel
    $day = Get-FmBusyMuseHead $rel; $rel = Get-FmBusyMuseTail $rel
    $session = Get-FmBusyMuseHead $rel
    $leaf = Get-FmBusyMuseTail $rel

    if ([string]::IsNullOrEmpty($year) -or [string]::IsNullOrEmpty($month) -or
        [string]::IsNullOrEmpty($day) -or [string]::IsNullOrEmpty($session)) {
        return $false
    }
    return [string]::Equals($leaf, 'session.jsonl', [System.StringComparison]::Ordinal)
}

# node's `directories()`: the child directory NAMES of <Parent>, with symlinked
# directories EXCLUDED (readdirSync's dirent reports a symlink as a symlink, not
# as a directory) and every error swallowed to an empty list.
function Get-FmBusyMuseChildDirectoryName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Parent = '')

    $names = [System.Collections.Generic.List[string]]::new()
    try {
        $info = [System.IO.DirectoryInfo]::new((ConvertTo-FmNativePath $Parent))
        foreach ($child in $info.GetDirectories()) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $names.Add($child.Name)
        }
    } catch {
        return , ([string[]]@())
    }
    return , ([string[]]$names.ToArray())
}

# node's `metadataWorkspace()`: the workspace_root recorded in the log's FIRST
# line, or $null. Bounded to the first 64 KiB exactly as the twin is - a first
# line longer than that is treated as unreadable rather than streamed, so one
# corrupt log cannot make every classification pay for it.
function Get-FmBusyMuseLogWorkspaceRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$SessionLog = '')

    $buffer = [byte[]]::new(65536)
    $length = 0
    try {
        $stream = [System.IO.File]::Open((ConvertTo-FmNativePath $SessionLog),
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        try {
            while ($length -lt $buffer.Length) {
                $read = $stream.Read($buffer, $length, $buffer.Length - $length)
                if ($read -le 0) { break }
                $length += $read
            }
        } finally { $stream.Dispose() }
    } catch {
        return $null
    }

    $newline = [Array]::IndexOf($buffer, [byte]10)
    if ($newline -lt 0 -or $newline -ge $length) { return $null }

    try {
        $text = [System.Text.UTF8Encoding]::new($false).GetString($buffer, 0, $newline)
        $record = $text | ConvertFrom-Json -AsHashtable
    } catch {
        return $null
    }
    # `record?.payload?.record?.workspace_root ?? null`, one optional hop at a
    # time so a non-object at any level is $null rather than a strict-mode throw.
    if ($record -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $record.Contains('payload')) { return $null }
    $payload = $record['payload']
    if ($payload -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $payload.Contains('record')) { return $null }
    $inner = $payload['record']
    if ($inner -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $inner.Contains('workspace_root')) { return $null }
    $value = $inner['workspace_root']
    if ($null -eq $value) { return $null }
    return [string]$value
}

<#
.SYNOPSIS
Every MAIN session log whose recorded workspace_root is this task's worktree.
.DESCRIPTION
Twin of fm_busy_muse_matching_logs, absorbing its inline node helper (see note 2
in the section header). The DEPTH BOUNDS are the load-bearing part: exactly
<root>/YYYY/MM/DD/<session>/session.jsonl is scanned, which excludes muse's own
native sub-agent logs one directory deeper.

Returns the array INTACT (`return , $array`), so an empty namespace arrives as a
0-element array rather than $null. Enumerate it directly - `foreach ($x in
(Get-FmBusyMuseMatchingLogs ...))`. Do NOT wrap the call in `@()`: that nests the
returned array one level deep and every element then reads as "System.String[]"
(the trap docs/powershell-port.md records, and the one this function was caught
by while being written).
#>
function Get-FmBusyMuseMatchingLogs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural matches both the bash twin''s name and the return shape: this yields every matching log, and the singular form would read as get-one-log.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$SessionsRoot = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$WorkspaceRoot = ''
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $SessionsRoot))) {
        return , ([string[]]@())
    }
    foreach ($year in (Get-FmBusyMuseChildDirectoryName $SessionsRoot)) {
        $yearPath = "$SessionsRoot/$year"
        foreach ($month in (Get-FmBusyMuseChildDirectoryName $yearPath)) {
            $monthPath = "$yearPath/$month"
            foreach ($day in (Get-FmBusyMuseChildDirectoryName $monthPath)) {
                $dayPath = "$monthPath/$day"
                foreach ($session in (Get-FmBusyMuseChildDirectoryName $dayPath)) {
                    $file = "$dayPath/$session/session.jsonl"
                    $native = ConvertTo-FmNativePath $file
                    # node's `lstatSync(file).isFile()`: a symlink is NOT a file.
                    if (-not [System.IO.File]::Exists($native)) { continue }
                    if (Test-FmSymlink $file) { continue }
                    $ws = Get-FmBusyMuseLogWorkspaceRoot $file
                    if ($null -eq $ws) { continue }
                    if ([string]::Equals($ws, $WorkspaceRoot, [System.StringComparison]::Ordinal)) {
                        $found.Add($file)
                    }
                }
            }
        }
    }
    return , ([string[]]$found.ToArray())
}

<#
.SYNOPSIS
Today's day directory under <SessionsRoot>.
.DESCRIPTION
Twin of fm_busy_muse_namespace_day. LOCAL time and InvariantCulture digits, so
the day never shifts with the host's calendar or number formatting. Only ONE
trailing '/' is stripped, exactly as `${1%/}` does.
#>
function Get-FmBusyMuseNamespaceDay {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$SessionsRoot = '')

    $root = $SessionsRoot
    if ($root.EndsWith('/', [System.StringComparison]::Ordinal)) {
        $root = $root.Substring(0, $root.Length - 1)
    }
    $today = [datetime]::Now.ToString('yyyy/MM/dd', [System.Globalization.CultureInfo]::InvariantCulture)
    return ('{0}/{1}' -f $root, $today)
}

<#
.SYNOPSIS
A cheap fingerprint of today's session namespace: 'missing', or "<crc>:<bytes>".
.DESCRIPTION
Twin of fm_busy_muse_namespace_signature. It is taken BEFORE and AFTER a
resolution scan, and a change between the two invalidates that scan - a session
created mid-scan means the "only new log" answer was raced and cannot be trusted.
It also pins the cache: a cached answer is reused only while the namespace is
byte-identical.

The manifest is `<path>:<crc>:<bytes>` per session log, one per line INCLUDING a
trailing newline, over paths sorted ORDINALLY (`LC_ALL=C sort`), each carrying
the cksum of that log's FIRST LINE. $null is bash's nonzero return.
#>
function Get-FmBusyMuseNamespaceSignature {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$DayDirectory = '')

    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $DayDirectory))) {
        return 'missing'
    }

    # `find "$1" -mindepth 2 -maxdepth 2 -type f -name session.jsonl`: exactly
    # <day>/<session>/session.jsonl, and -type f is false for a symlink because
    # find does not follow by default.
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($session in (Get-FmBusyMuseChildDirectoryName $DayDirectory)) {
        $file = "$DayDirectory/$session/session.jsonl"
        $native = ConvertTo-FmNativePath $file
        if (-not [System.IO.File]::Exists($native)) { continue }
        if (Test-FmSymlink $file) { continue }
        $paths.Add($file)
    }
    $sorted = $paths.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)

    $manifest = [System.Text.StringBuilder]::new()
    foreach ($path in $sorted) {
        # `first=$(sed -n '1p' "$path")`: the first line WITHOUT its terminator,
        # and with any CR kept - $() strips only trailing newlines.
        $text = Get-FmFileText $path
        $cut = $text.IndexOf("`n")
        $first = if ($cut -ge 0) { $text.Substring(0, $cut) } else { $text }
        [void]$manifest.Append($path).Append(':').Append((Get-FmBusyCksumText $first)).Append("`n")
    }
    $signature = Get-FmBusyCksumText $manifest.ToString()
    if ([string]::IsNullOrEmpty($signature)) { return $null }
    return $signature
}

<#
.SYNOPSIS
The cached session log, when the cache is still provably this pane's.
.DESCRIPTION
Twin of fm_busy_muse_cached_session_log. Every one of the five checks must hold:
the cache names THIS binding, the log is still a valid main log under the root,
the log is not one the sidecar recorded as pre-existing, and both the day and its
namespace signature are unchanged. Any miss yields $null and the caller rescans.
#>
function Get-FmBusyMuseCachedSessionLog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$SessionsRoot = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$BindingId = ''
    )

    if ([string]::IsNullOrEmpty($BindingId)) { return $null }
    $cacheBinding = Get-FmBusyMuseCacheField $StateDir $Id 'binding_id'
    if ($null -eq $cacheBinding) { return $null }
    if (-not [string]::Equals($cacheBinding, $BindingId, [System.StringComparison]::Ordinal)) { return $null }
    $log = Get-FmBusyMuseCacheField $StateDir $Id 'session_log'
    if ($null -eq $log) { return $null }
    if (-not (Test-FmBusyMuseMainLogPathValid $SessionsRoot $log)) { return $null }
    if (Test-FmBusyMuseBindingHasPriorLog $StateDir $Id $log) { return $null }
    $cacheDay = Get-FmBusyMuseCacheField $StateDir $Id 'namespace_day'
    if ($null -eq $cacheDay) { return $null }
    $cacheSignature = Get-FmBusyMuseCacheField $StateDir $Id 'namespace_signature'
    if ($null -eq $cacheSignature) { return $null }
    $day = Get-FmBusyMuseNamespaceDay $SessionsRoot
    if (-not [string]::Equals($cacheDay, $day, [System.StringComparison]::Ordinal)) { return $null }
    $signature = Get-FmBusyMuseNamespaceSignature $day
    if ($null -eq $signature) { return $null }
    if (-not [string]::Equals($cacheSignature, $signature, [System.StringComparison]::Ordinal)) { return $null }
    return $log
}

<#
.SYNOPSIS
Publish the resolution cache, if the binding still matches.
.DESCRIPTION
Twin of fm_busy_muse_cache_session_log. An EMPTY binding id is success without a
write (bash's `[ -n "$3" ] || return 0`): there is nothing to key a cache on, and
the caller must still return its freshly resolved log. A binding that has moved
on since resolution began is a failure, so a cache is never written against a
relaunched pane's identity.
#>
function Write-FmBusyMuseSessionLogCache {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$BindingId = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$SessionLog = '',
        [Parameter(Position = 4)][AllowEmptyString()][string]$NamespaceDay = '',
        [Parameter(Position = 5)][AllowEmptyString()][string]$NamespaceSignature = ''
    )

    if ([string]::IsNullOrEmpty($BindingId)) { return $true }
    $current = Get-FmBusyMuseBindingField $StateDir $Id 'binding_id'
    if ($null -eq $current) { return $false }
    if (-not [string]::Equals($current, $BindingId, [System.StringComparison]::Ordinal)) { return $false }
    $body = "binding_id=$BindingId`nsession_log=$SessionLog`n" +
            "namespace_day=$NamespaceDay`nnamespace_signature=$NamespaceSignature`n"
    return (Set-FmFileTextAtomic -Path (Get-FmBusyMuseCachePath $StateDir $Id) -Text $body -NoNewline)
}

<#
.SYNOPSIS
The one MAIN session log that did not exist when this pane's binding was created.
.DESCRIPTION
Twin of fm_busy_muse_session_log. TWO candidates are AMBIGUOUS and fail closed
rather than guessing which pane owns either log, and a namespace that changed
under the scan invalidates the whole answer. $null is bash's nonzero return,
which the classifier reads as `unknown muse-session-log`.
#>
function Get-FmBusyMuseSessionLog {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
    )

    $root = Get-FmBusyMuseBindingField $StateDir $Id 'sessions_root'
    if ($null -eq $root) { return $null }
    $ws = Get-FmBusyMuseBindingField $StateDir $Id 'workspace_root'
    if ($null -eq $ws) { return $null }
    # The twin swallows this one's failure (`|| true`), so an absent binding_id
    # is an empty string here and merely disables the cache.
    $bindingId = Get-FmBusyMuseBindingField $StateDir $Id 'binding_id'
    if ($null -eq $bindingId) { $bindingId = '' }

    $cached = Get-FmBusyMuseCachedSessionLog $StateDir $Id $root $bindingId
    if (-not [string]::IsNullOrEmpty($cached)) { return $cached }

    $cachePath = ConvertTo-FmNativePath (Get-FmBusyMuseCachePath $StateDir $Id)
    try { [System.IO.File]::Delete($cachePath) } catch { $null = $_ }   # `rm -f`

    $namespaceDay = Get-FmBusyMuseNamespaceDay $root
    $namespaceBefore = Get-FmBusyMuseNamespaceSignature $namespaceDay
    if ($null -eq $namespaceBefore) { return $null }

    $selected = ''
    # NOT `@(...)`: see Get-FmBusyMuseMatchingLogs' return-shape note.
    foreach ($candidate in (Get-FmBusyMuseMatchingLogs $root $ws)) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        if (Test-FmBusyMuseBindingHasPriorLog $StateDir $Id $candidate) { continue }
        if (-not [string]::IsNullOrEmpty($selected)) { return $null }   # ambiguous
        $selected = $candidate
    }
    if ([string]::IsNullOrEmpty($selected)) { return $null }

    $namespaceAfter = Get-FmBusyMuseNamespaceSignature $namespaceDay
    if ($null -eq $namespaceAfter) { return $null }
    if (-not [string]::Equals($namespaceBefore, $namespaceAfter, [System.StringComparison]::Ordinal)) {
        return $null
    }
    if (-not (Write-FmBusyMuseSessionLogCache $StateDir $Id $bindingId $selected `
                $namespaceDay $namespaceAfter)) {
        return $null
    }
    return $selected
}

<#
.SYNOPSIS
The run lifecycle records in one session log, as RunId/Event/Terminal triples.
.DESCRIPTION
Twin of fm_busy_muse_run_events. The match is anchored on the EXACT structural
prefix

    "payload":{"kind":"run","run_id":"<id>","event":{"kind":"<event>"

rather than a bare "kind":"terminal" search, because muse also emits nested
"record":{"kind":"terminal"} cleanup-effect payloads that are NOT run terminals
and would otherwise close a run that is still in flight. A line whose bytes do
not match that shape exactly is skipped, never guessed at.

Returns the array INTACT (`return , $array`), which is what lets a caller tell a
MISSING log ($null, bash's nonzero return) from a log with no run records (a
0-element array). Enumerate it directly; wrapping the call in `@()` would nest
the array one level deep.
#>
function Get-FmBusyMuseRunEvents {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural matches both the bash twin''s name and the return shape: this yields every run lifecycle record in the log.')]
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$SessionLog = '')

    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $SessionLog))) { return $null }

    $pre = '"payload":{"kind":"run","run_id":"'
    $head = '","event":{"kind":"'
    $marker = '"terminal":"'
    $ordinal = [System.StringComparison]::Ordinal
    $events = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($line in (Get-FmFileLines $SessionLog)) {
        $p = $line.IndexOf($pre, $ordinal)
        if ($p -lt 0) { continue }
        $rest = $line.Substring($p + $pre.Length)
        $q = $rest.IndexOf('"', $ordinal)
        if ($q -lt 0) { continue }
        $rid = $rest.Substring(0, $q)
        $rest = $rest.Substring($q)              # awk's substr(rest, q): AT the quote
        if (-not $rest.StartsWith($head, $ordinal)) { continue }
        $rest = $rest.Substring($head.Length)
        $q = $rest.IndexOf('"', $ordinal)
        if ($q -lt 0) { continue }
        $ev = $rest.Substring(0, $q)
        $terminal = ''
        if ([string]::Equals($ev, 'terminal', $ordinal)) {
            $p = $rest.IndexOf($marker, $ordinal)
            if ($p -ge 0) {
                $value = $rest.Substring($p + $marker.Length)
                $q = $value.IndexOf('"', $ordinal)
                if ($q -ge 0) { $terminal = $value.Substring(0, $q) }
            }
        }
        if ([string]::Equals($ev, 'started', $ordinal) -or [string]::Equals($ev, 'terminal', $ordinal)) {
            $events.Add(@{ RunId = $rid; Event = $ev; Terminal = $terminal })
        }
    }
    return , ([hashtable[]]$events.ToArray())
}

<#
.SYNOPSIS
Fold one session log to busy|settled|none.
.DESCRIPTION
Twin of fm_busy_muse_run_state.

  busy     at least one run started with no matching terminal
  settled  every started run reached a terminal
  none     the log holds no run lifecycle records at all

$null when the log does not exist, which the classifier reads as unknown.
#>
function Get-FmBusyMuseRunState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$SessionLog = '')

    $events = Get-FmBusyMuseRunEvents $SessionLog
    if ($null -eq $events) { return $null }

    $open = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)
    $seen = $false
    foreach ($e in $events) {
        if ($e.Event -ceq 'started') { $open[$e.RunId] = $true; $seen = $true }
        elseif ($e.Event -ceq 'terminal') { $open[$e.RunId] = $false }
    }
    if (-not $seen) { return 'none' }
    foreach ($value in $open.Values) { if ($value) { return 'busy' } }
    return 'settled'
}

<#
.SYNOPSIS
The single open run id, when there is EXACTLY one.
.DESCRIPTION
Twin of fm_busy_muse_active_run_id. Zero or two-or-more open runs yield $null
(bash's `exit 1`), because an interrupt acknowledgement must be attributed to one
unambiguous run or not at all.

Note the twin's asymmetry, preserved here: a `terminal` for a run never
`started` in this log still registers that run as not-open, so it is counted in
the map but never returned.
#>
function Get-FmBusyMuseActiveRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$SessionLog = '')

    $events = Get-FmBusyMuseRunEvents $SessionLog
    if ($null -eq $events) { return $null }

    $open = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $events) {
        if ($e.Event -ceq 'started') { $open[$e.RunId] = $true }
        elseif ($e.Event -ceq 'terminal') { $open[$e.RunId] = $false }
    }
    $active = ''
    $count = 0
    foreach ($pair in $open.GetEnumerator()) {
        if (-not $pair.Value) { continue }
        $active = $pair.Key
        $count++
    }
    if ($count -ne 1) { return $null }
    return $active
}

<#
.SYNOPSIS
The terminal disposition recorded for <RunId>, or $null.
.DESCRIPTION
Twin of fm_busy_muse_run_terminal: the LAST non-empty terminal value for that run
id ("completed", "cancelled", ...). $null when the run has no terminal yet, which
is how the control plane tells "the interrupt landed" from "the turn is still
running".
#>
function Get-FmBusyMuseRunTerminal {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$SessionLog = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$RunId = ''
    )

    if ([string]::IsNullOrEmpty($RunId)) { return $null }
    $events = Get-FmBusyMuseRunEvents $SessionLog
    if ($null -eq $events) { return $null }

    $terminal = ''
    foreach ($e in $events) {
        if ($e.RunId -cne $RunId) { continue }
        if ($e.Event -cne 'terminal') { continue }
        if ([string]::IsNullOrEmpty($e.Terminal)) { continue }
        $terminal = $e.Terminal
    }
    if ([string]::IsNullOrEmpty($terminal)) { return $null }
    return $terminal
}

<#
.SYNOPSIS
The Grok-only temporary rendered-tail fallback.
.DESCRIPTION
Twin of fm_busy_grok_tail_busy:

    grep -v '^[[:space:]]*$' | tail -12 | grep -qiE "<signature>"

True when Grok's verified busy signature matches the last 12 non-blank lines.
FM_BUSY_REGEX still globally overrides the signature, mirroring the historical
operator escape hatch.

Three fidelity choices, each deliberate:

  - The blank-line filter is '\A[ \t\v\f\r]*\z', the ASCII set POSIX
    [[:space:]] names, NOT \s. .NET's \s also matches U+00A0 and the other
    Unicode spaces, which glibc does not classify as space - so \s would drop a
    line that grep keeps, and a 12-line window would silently shift.
  - The default signature falls back through FM_TMUX_GROK_BUSY_REGEX_DEFAULT for
    symmetry with the twin, which reads it as a SHELL variable set by
    bin/fm-tmux-lib.sh (itself an undeclared dependency). Both spellings of the
    default are the identical literal 'Ctrl\+c:cancel', so the two worlds agree
    whether or not that lib is loaded - but a wave-3 author who changes the
    tmux-lib default must change this literal in the same breath.
  - Matching is IgnoreCase (grep -i) plus CultureInvariant, so a host locale
    cannot change which panes read busy. POSIX ERE and .NET regex agree on
    everything the signature and every override in this tree uses; they diverge
    only on POSIX bracket expressions such as [[:alpha:]], which .NET does not
    support at all. An operator override using one would fail here rather than
    matching differently - worth knowing, not worth emulating.
#>
function Test-FmBusyGrokTail {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Tail = '')

    $pattern = Get-FmEnv 'FM_BUSY_REGEX'
    if ([string]::IsNullOrEmpty($pattern)) {
        $pattern = Get-FmEnv 'FM_TMUX_GROK_BUSY_REGEX_DEFAULT' 'Ctrl\+c:cancel'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ([string]$Tail -split "`n")) {
        if ($line -cmatch '\A[ \t\v\f\r]*\z') { continue }
        $lines.Add($line)
    }
    if ($lines.Count -eq 0) { return $false }
    $start = [Math]::Max(0, $lines.Count - 12)

    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
               [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    for ($i = $start; $i -lt $lines.Count; $i++) {
        try {
            if ([System.Text.RegularExpressions.Regex]::IsMatch($lines[$i], $pattern, $options)) {
                return $true
            }
        } catch {
            # An operator override that .NET cannot compile is a NO-MATCH, not a
            # crash: grep would have refused the pattern and exited non-zero,
            # which the twin's pipeline reads as "not busy". Reported once so a
            # broken override is visible rather than mysteriously idle.
            Write-FmLog -Prefix 'fm-busy-lib.psm1' "unusable busy signature '$pattern': $($_.Exception.Message)"
            return $false
        }
    }
    return $false
}

<#
.SYNOPSIS
Semantic classification for a task whose endpoint the caller has established.
.DESCRIPTION
Twin of fm_busy_classify. Returns "<verdict> <source>" as one string -
busy|idle|unknown plus the producing source (see the module header) - because
every consumer in the tree parses exactly that shape (`${verdict%% *}`), and
splitting it into an object here would fork the contract mid-conversion.

Never probes process state. <Tail> is optional pre-captured plain output used
only by the Grok arm; when absent the Grok arm captures through the probed
backend capture command if one is available, else reports unknown capture-failed.
#>
function Get-FmBusyClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Harness = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 4)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 5)][AllowNull()][AllowEmptyString()][string]$Tail = ''
    )

    # The two verification gates run BEFORE any record is read: an unverified
    # adapter must never be classified by a record, however well-formed, because
    # nothing has proven its writer brackets a real turn.
    if ($Harness -clike 'kimi*') {
        if (-not (Test-FmBusyKimiVerified)) { return 'unknown kimi-unverified' }
    } elseif ($Harness -clike 'codex*') {
        if (-not (Test-FmBusyCodexSemanticSource)) { return 'unknown codex-unverified' }
    }

    $record = Read-FmBusyRecord $StateDir $Id
    if ($record.Ok) {
        if (Test-FmBusySourceTrusted $Harness $record.Source) {
            return ('{0} {1}' -f $record.State, $record.Source)
        }
        return 'unknown source-mismatch'
    }
    if ($record.Reason -ceq 'malformed' -or $record.Reason -ceq 'gen-mismatch') {
        return ('unknown {0}' -f $record.Reason)
    }

    # No record at all. A native herdr busy verdict is semantic enough to trust
    # for BUSY (streaming means a turn is running); native idle is narrower
    # than turn state (a long foreground tool call reads idle) and stays
    # unknown here.
    if ($Backend -ceq 'herdr') {
        $busyCmd = Get-FmBusyBackendCommand 'BusyState'
        if ($null -ne $busyCmd) {
            $native = ''
            try {
                $native = ([string](& $busyCmd $Backend $Target)).TrimEnd("`n")
            } catch {
                # `|| true` in the twin: a failing native probe is not a verdict.
                $native = ''
            }
            if ($native -ceq 'busy') { return 'busy herdr-native' }
        }
    }

    if ($Harness -clike 'muse*') {
        # Semantic, on demand: fold this task's bound session log. An open run is
        # positive proof of a turn in flight and a settled log is a finished turn.
        # Every other outcome - no sidecar, no matching log, an unreadable or
        # run-free log - is unknown, NEVER idle.
        $log = Get-FmBusyMuseSessionLog $StateDir $Id
        if ([string]::IsNullOrEmpty($log)) { return 'unknown muse-session-log' }
        $runState = Get-FmBusyMuseRunState $log
        if ($runState -ceq 'busy') { return 'busy muse-session-log' }
        if ($runState -ceq 'settled') { return 'idle muse-session-log' }
        return 'unknown muse-session-log'
    }

    if ($Harness -clike 'grok*') {
        if ([string]::IsNullOrEmpty($Tail)) {
            $captureCmd = Get-FmBusyBackendCommand 'Capture'
            if ($null -eq $captureCmd) { return 'unknown capture-failed' }
            $captured = $null
            try {
                $captured = & $captureCmd $Backend $Target 40
            } catch {
                return 'unknown capture-failed'
            }
            if ($null -eq $captured) { return 'unknown capture-failed' }
            # A capture that SUCCEEDS with empty output is not a failure: the
            # twin only branches on the exit status, and an empty tail then
            # classifies idle. Lines come back joined with LF because the tail
            # is matched as text.
            if ($captured -is [array]) {
                $Tail = ($captured -join "`n")
            } else {
                $Tail = [string]$captured
            }
        }
        if (Test-FmBusyGrokTail $Tail) { return 'busy grok-regex' }
        return 'idle grok-regex'
    }

    return 'unknown missing'
}

<#
.SYNOPSIS
Get-FmBusyClassification behind the one process-level override.
.DESCRIPTION
Twin of fm_busy_classify_live: a gone endpoint is dead, never busy. Requires the
probed Test-FmBackendTargetExists (the fm-backend seam in the module header);
when it is absent - the expected state until wave 3 - every live classification
is 'dead endpoint-gone', which is precisely what the bash twin produces when
fm-backend.sh was not sourced.

<Label> is the expected endpoint label, forwarded to the probe. Note that the
twin does NOT forward it as a tail: the Grok arm below always re-captures.
#>
function Get-FmBusyLiveClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Harness = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 4)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 5)][AllowEmptyString()][string]$Label = ''
    )

    if ([string]::IsNullOrEmpty($Target)) { return 'unknown no-target' }

    $exists = $false
    $existsCmd = Get-FmBusyBackendCommand 'TargetExists'
    if ($null -ne $existsCmd) {
        try {
            $exists = [bool](& $existsCmd $Backend $Target $Label)
        } catch {
            # Present but unusable means the signature contract in the header was
            # broken. Loud, because a silent 'dead' verdict here would look like
            # a crashed worker and could tear down healthy work. An ABSENT
            # command stays silent: that is the expected pre-wave-3 state, and
            # the twin suppresses its own not-found noise with 2>/dev/null.
            Write-FmLog -Prefix 'fm-busy-lib.psm1' "$($existsCmd.Name) failed: $($_.Exception.Message)"
            $exists = $false
        }
    }
    if (-not $exists) { return 'dead endpoint-gone' }

    return Get-FmBusyClassification $Backend $Target $Harness $Id $StateDir
}

<#
.SYNOPSIS
Classify a task from its recorded metadata.
.DESCRIPTION
Twin of fm_busy_classify_meta, so every consumer resolves backend, target, and
harness the same way instead of re-deriving them. harness comes from
fm-common's Get-FmMetaValue, which is already byte-compatible with the bash
fm_meta_get; backend and target come through the fm-backend seam (module
header), and when those probes miss, this returns 'unknown no-target' - the same
verdict bash produces from its empty command substitutions - plus one stderr
diagnostic, because the twin is not quiet on that path either.
#>
function Get-FmBusyMetaClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$MetaPath = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 3)][AllowNull()][AllowEmptyString()][string]$Tail = ''
    )

    if ([string]::IsNullOrEmpty($MetaPath) -or
        -not [System.IO.File]::Exists((ConvertTo-FmNativePath $MetaPath))) {
        return 'unknown missing'
    }

    $backend = ''
    $target = ''
    $backendCmd = Get-FmBusyBackendCommand 'MetaBackend'
    $targetCmd = Get-FmBusyBackendCommand 'MetaTarget'
    if ($null -eq $backendCmd -or $null -eq $targetCmd) {
        Write-FmLog -Prefix 'fm-busy-lib.psm1' 'backend meta resolution unavailable (fm-backend not loaded); classifying unknown no-target'
    } else {
        try {
            $backend = [string](& $backendCmd $MetaPath)
            $target = [string](& $targetCmd $MetaPath)
        } catch {
            Write-FmLog -Prefix 'fm-busy-lib.psm1' "backend meta resolution failed: $($_.Exception.Message)"
            $backend = ''
            $target = ''
        }
    }
    $harness = Get-FmMetaValue $MetaPath 'harness'

    if ([string]::IsNullOrEmpty($target)) { return 'unknown no-target' }

    return Get-FmBusyClassification $backend $target $harness $Id $StateDir $Tail
}

<#
.SYNOPSIS
Boolean view for callers that only gate on provable activity.
.DESCRIPTION
Twin of fm_busy_is_busy. True iff the classification verdict is exactly busy;
idle, unknown, and dead are all false, so an unknown can never be silently
promoted to either boolean pole - callers that must distinguish idle from
unknown read Get-FmBusyClassification instead.
#>
function Test-FmBusy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Harness = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$Id = '',
        [Parameter(Position = 4)][AllowEmptyString()][string]$StateDir = '',
        [Parameter(Position = 5)][AllowNull()][AllowEmptyString()][string]$Tail = ''
    )

    $verdict = Get-FmBusyClassification $Backend $Target $Harness $Id $StateDir $Tail
    return (($verdict -split ' ', 2)[0] -ceq 'busy')
}

Export-ModuleMember -Function @(
    'Get-FmBusyLibVersion',
    'Test-FmBusyKimiVerified',
    'Test-FmBusyCodexAppServerObservable', 'Test-FmBusyCodexHooksVerified',
    'Test-FmBusyCodexSemanticSource',
    'Get-FmBusyRecordPath', 'Get-FmBusyGenPath',
    'Test-FmBusyToken', 'Get-FmBusyCurrentGen',
    'Get-FmBusySourcesForHarness', 'Test-FmBusySourceTrusted',
    'Read-FmBusyRecord', 'Test-FmBusyGrokTail',
    'Get-FmBusyMuseBindingPath', 'Get-FmBusyMuseCachePath',
    'Get-FmBusyMuseBindingField', 'Get-FmBusyMuseCacheField',
    'Test-FmBusyMuseBindingHasPriorLog', 'Test-FmBusyMuseMainLogPathValid',
    'Get-FmBusyMuseMatchingLogs', 'Get-FmBusyMuseNamespaceDay',
    'Get-FmBusyMuseNamespaceSignature', 'Get-FmBusyMuseCachedSessionLog',
    'Write-FmBusyMuseSessionLogCache', 'Get-FmBusyMuseSessionLog',
    'Get-FmBusyMuseRunEvents', 'Get-FmBusyMuseRunState',
    'Get-FmBusyMuseActiveRunId', 'Get-FmBusyMuseRunTerminal',
    'Get-FmBusyClassification', 'Get-FmBusyLiveClassification',
    'Get-FmBusyMetaClassification', 'Test-FmBusy'
)
