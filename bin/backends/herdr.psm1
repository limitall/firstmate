# bin/backends/herdr.psm1 - the herdr session-provider adapter (EXPERIMENTAL).
#
# Twin: bin/backends/herdr.sh
#
# Design: data/fm-backend-design-d7/herdr-addendum.md ("Interface mapping",
# decisions D1-D6) and the empirical verification in
# data/fm-backend-design-d7/herdr-verification-p2.md, refined by
# docs/herdr-backend.md. Herdr is a session provider ONLY (D3): the worktree
# provider stays treehouse, exactly like tmux. Imported only through
# bin/fm-backend.psm1's Import-FmBackendAdapter, never directly.
#
# EVERY SAFETY BOUNDARY IN THE BASH TWIN IS REPRODUCED HERE UNCHANGED. This
# adapter's comments encode incidents that cost real work, and each one is
# restated at the function that owns it rather than summarized away:
#
#   * The seeded default-tab prune acts ONLY on a tab id captured from the same
#     `workspace create` response (2026-07-02 self-kill). An ADOPTED workspace
#     supplies no seeded tab id and can never enter the prune path, whatever its
#     tabs are labeled. See Remove-FmBackendHerdrSeededDefaultTab.
#   * Get-FmBackendHerdrAgentState's verdicts are RECOVERY-GRADE. Only a
#     definitive pane_not_found is `missing`; every other read failure is
#     `unreadable`, never `dead`, because a transient error that read as dead
#     would license a duplicate spawn against a live crew.
#   * Every projection mutation captures the exact active workspace/tab first and
#     REFUSES rather than proceeding when it cannot.
#   * Nothing here ever targets the `default` session implicitly: every call
#     carries an explicit trailing `--session <name>` (Invoke-FmBackendHerdrCli).
#
# ============================================================================
# BASH -> POWERSHELL SURFACE MAP. Complete rather than illustrative, because
# W4-spawn, W4-teardown, W4-watch and W4-herdr-ops are all written against it,
# and it names each function's RETURN CONVENTION - a bash function has one
# channel (stdout plus an exit status) and these have two.
#
#   bin/backends/herdr.sh                       this file                                     returns
#   ------------------------------------------  --------------------------------------------  -------------------------------
#   -- CLI, tooling, session ---------------------------------------------------------------------------------------------
#   fm_backend_herdr_cli                        Invoke-FmBackendHerdrCli                      @{ExitCode;StdOut;StdErr;Ok}
#   fm_backend_herdr_tool_check                 Test-FmBackendHerdrTool                       [bool] (+ stderr refusal)
#   fm_backend_herdr_version_check              Test-FmBackendHerdrVersion                    [bool] (+ stderr refusal)
#   fm_backend_herdr_session                    Get-FmBackendHerdrSession                     session name
#   fm_backend_herdr_server_ensure              Initialize-FmBackendHerdrServer               [bool]
#   fm_backend_herdr_workspace_label            Get-FmBackendHerdrWorkspaceLabel              label
#   fm_backend_herdr_parse_target               Get-FmBackendHerdrTarget                      @{Session;Pane} or $null
#   fm_backend_herdr_target_ready               Test-FmBackendHerdrTargetReady                @{Session;Pane} or $null
#   fm_backend_herdr_normalize_host_path        ConvertTo-FmBackendHerdrHostPath              path
#   fm_backend_herdr_normalize_key              ConvertTo-FmBackendHerdrKey                   herdr key name
#   -- presentation journal ----------------------------------------------------------------------------------------------
#   fm_backend_herdr_projection_id              New-FmBackendHerdrProjectionId                22-char token, or $null
#   fm_backend_herdr_projection_journal_path    Get-FmBackendHerdrProjectionJournalPath       path
#   fm_backend_herdr_projection_journal_create  New-FmBackendHerdrProjectionJournal           token, or $null (+ refusal)
#   fm_backend_herdr_projection_journal_field   Get-FmBackendHerdrProjectionJournalField      value, or $null
#   fm_backend_herdr_projection_journal_snapshot Get-FmBackendHerdrProjectionJournalSnapshot  @{Version;TaskId;...} or $null
#   fm_backend_herdr_projection_journal_token   Get-FmBackendHerdrProjectionJournalToken      token, or $null
#   fm_backend_herdr_projection_journal_write_v2 Write-FmBackendHerdrProjectionJournalV2      [bool]
#   fm_backend_herdr_projection_journal_bind    Set-FmBackendHerdrProjectionJournalBinding    [bool]
#   fm_backend_herdr_projection_journal_replace_endpoint Update-FmBackendHerdrProjectionJournalEndpoint [bool]
#   fm_backend_herdr_projection_home_identity   Get-FmBackendHerdrProjectionHomeIdentity      POSIX path, or $null
#   fm_backend_herdr_projection_concise_task_label Get-FmBackendHerdrProjectionConciseTaskLabel  label
#   fm_backend_herdr_projection_workspace_label Get-FmBackendHerdrProjectionWorkspaceLabel    label
#   -- session presentation lock -----------------------------------------------------------------------------------------
#   fm_backend_herdr_presentation_lock_namespace Get-FmBackendHerdrPresentationLockNamespace  path
#   fm_backend_herdr_presentation_lock_namespace_mode Get-FmBackendHerdrPresentationLockNamespaceMode  octal, or $null
#   fm_backend_herdr_presentation_lock_namespace_uid  Get-FmBackendHerdrPresentationLockNamespaceUid   uid, or $null
#   fm_backend_herdr_presentation_lock_namespace_valid Test-FmBackendHerdrPresentationLockNamespace    [bool]
#   fm_backend_herdr_canonical_socket_path      Get-FmBackendHerdrCanonicalSocketPath         POSIX path, or $null
#   fm_backend_herdr_presentation_session_socket_path Get-FmBackendHerdrPresentationSessionSocketPath  POSIX path, or $null
#   fm_backend_herdr_presentation_session_lock_path   Get-FmBackendHerdrPresentationSessionLockPath    lock path, or $null
#   -- focus, close plans, removal ---------------------------------------------------------------------------------------
#   fm_backend_herdr_projection_focus_snapshot  Get-FmBackendHerdrProjectionFocusSnapshot     "ws<TAB>tab", or $null
#   fm_backend_herdr_projection_focus_restore   Restore-FmBackendHerdrProjectionFocus         [bool] (+ warnings)
#   fm_backend_herdr_projection_close_pane_focus_preserving Close-FmBackendHerdrProjectionPane @{Code;AgentState}
#   fm_backend_herdr_workspace_move_capable     Test-FmBackendHerdrWorkspaceMoveCapable       [int] 0 ok, 1..5 reason
#   fm_backend_herdr_emptying_close_plan        Get-FmBackendHerdrEmptyingClosePlan           @{Plan;ShellPid;MoveRecord}
#   fm_backend_herdr_emptying_move_rollback     Restore-FmBackendHerdrEmptyingMove            [bool] (+ warnings)
#   fm_backend_herdr_death_close_pane           Close-FmBackendHerdrPaneByDeath               [bool]
#   fm_backend_herdr_explicit_close_pane_confirmed Close-FmBackendHerdrPaneExplicit           [bool]
#   fm_backend_herdr_pid_is_bare_shell          Test-FmBackendHerdrBareShellPid               [bool]
#   fm_backend_herdr_pane_idle_shell_pid        Get-FmBackendHerdrPaneIdleShellPid            pid, or $null
#   fm_backend_herdr_pane_idle_shell_sample     Get-FmBackendHerdrPaneIdleShellSample         pid, or $null
#   -- containers and tasks ----------------------------------------------------------------------------------------------
#   fm_backend_herdr_workspace_find_all         Get-FmBackendHerdrWorkspaceMatch              [string[]]
#   fm_backend_herdr_workspace_find             Get-FmBackendHerdrWorkspace                   id, or ''
#   fm_backend_herdr_launcher_identity          Get-FmBackendHerdrLauncherIdentity            @{Code;PaneId;TabId;WorkspaceId}
#   fm_backend_herdr_workspace_prune_seeded_default_tab Remove-FmBackendHerdrSeededDefaultTab [bool]
#   fm_backend_herdr_workspace_ensure           Initialize-FmBackendHerdrWorkspace            @{Code;WorkspaceId;SeededTabId}
#   fm_backend_herdr_container_ensure           Initialize-FmBackendHerdrContainer            "sess:ws<TAB>seeded", or $null
#   fm_backend_herdr_create_task                New-FmBackendHerdrTask                        "<tab> <pane>", or $null
#   fm_backend_herdr_pane_for_tab               Get-FmBackendHerdrPaneForTab                  pane id, or $null
#   fm_backend_herdr_resolve_bare_selector      Resolve-FmBackendHerdrBareSelector            "sess:pane", or $null
#   fm_backend_herdr_list_live                  Get-FmBackendHerdrLiveTask                    [string[]] "sess:pane<TAB>label"
#   -- presence, agents, husks -------------------------------------------------------------------------------------------
#   fm_backend_herdr_pane_presence_state        Get-FmBackendHerdrPanePresenceState           dead|present|unknown
#   fm_backend_herdr_workspace_presence_state   Get-FmBackendHerdrWorkspacePresenceState      dead|present|unknown
#   fm_backend_herdr_pane_agent_state           Get-FmBackendHerdrPaneAgentState              dead|no-agent|live|unknown
#   fm_backend_herdr_tab_is_husk                Test-FmBackendHerdrTabIsHusk                  [bool]
#   fm_backend_herdr_agent_state                Get-FmBackendHerdrAgentState                  alive|dead|missing|unreadable
#   fm_backend_herdr_agent_alive                Get-FmBackendHerdrAgentAlive                  alive|dead|unknown
#   fm_backend_herdr_agent_status_raw           Get-FmBackendHerdrAgentStatusRaw              raw status, or ''
#   fm_backend_herdr_agent_identity_raw         Get-FmBackendHerdrAgentIdentityRaw            "agent<TAB>status", or $null
#   fm_backend_herdr_classify_agent_status      Get-FmBackendHerdrAgentStatusClass            busy|idle|unknown
#   fm_backend_herdr_classify_submit_agent_status Get-FmBackendHerdrSubmitStatusClass         busy|idle|unknown
#   fm_backend_herdr_busy_state                 Get-FmBackendHerdrBusyState                   busy|idle|unknown
#   fm_backend_herdr_endpoint_confirmed_gone    Test-FmBackendHerdrEndpointGone               [bool]
#   -- projection lifecycle ----------------------------------------------------------------------------------------------
#   fm_backend_herdr_projection_create_task     New-FmBackendHerdrProjectionTask              @{Ok;Session;WorkspaceId;...}
#   fm_backend_herdr_projection_cleanup_exact   Clear-FmBackendHerdrProjectionExact           [void]
#   fm_backend_herdr_projection_parent_workspace_exact Get-FmBackendHerdrProjectionParentWorkspace  id, or $null
#   fm_backend_herdr_projection_live_binding_matches Test-FmBackendHerdrProjectionLiveBinding  [bool]
#   fm_backend_herdr_projection_reclaim_rollback Undo-FmBackendHerdrProjectionReclaim         [bool]
#   fm_backend_herdr_projection_reclaim_task    Restore-FmBackendHerdrProjectionTask          @{Code;TabId;PaneId}
#   fm_backend_herdr_projection_recovery_allows_flat Test-FmBackendHerdrProjectionFlatFallback [bool]
#   fm_backend_herdr_projection_endpoint_matches_journal Test-FmBackendHerdrProjectionEndpointJournal [bool]
#   fm_backend_herdr_projection_order_best_effort Set-FmBackendHerdrProjectionOrder            [void] (always succeeds)
#   -- IO into a pane ----------------------------------------------------------------------------------------------------
#   fm_backend_herdr_pane_posixify              Initialize-FmBackendHerdrPaneShell            [bool] - SEE "PANE BOOTSTRAP"
#   fm_backend_herdr_current_path               Get-FmBackendHerdrCurrentPath                 path, or ''
#   fm_backend_herdr_current_path_probe         Get-FmBackendHerdrCurrentPathProbe            path, or ''
#   fm_backend_herdr_send_text_line             Send-FmBackendHerdrTextLine                   [bool]
#   fm_backend_herdr_send_literal               Send-FmBackendHerdrLiteral                    [bool]
#   fm_backend_herdr_send_key                   Send-FmBackendHerdrKey                        [bool]
#   fm_backend_herdr_send_text_submit           Send-FmBackendHerdrTextSubmit                 empty|pending|unknown|send-failed
#   fm_backend_herdr_capture                    Get-FmBackendHerdrCapture                     capture text, or $null
#   fm_backend_herdr_capture_ansi               Get-FmBackendHerdrCaptureAnsi                 capture text, or $null
#   fm_backend_herdr_strip_ansi                 (fm-composer-lib) Get-FmComposerPlainText     -- see NO SECOND STRIPPER
#   fm_backend_herdr_composer_state             Get-FmBackendHerdrComposerState               empty|pending|unknown
#   fm_backend_herdr_pi_separator_row           Test-FmBackendHerdrPiSeparatorRow             [bool]
#   fm_backend_herdr_pi_composer_find           Get-FmBackendHerdrPiComposer                  @{Found;Valid;OpenLine;...}
#   fm_backend_herdr_submit_confirm_budget      Get-FmBackendHerdrSubmitConfirmBudget         "%.4f" seconds
#   fm_backend_herdr_wait_for_working            Wait-FmBackendHerdrWorking                    busy|idle|unknown
#   fm_backend_herdr_kill                        Remove-FmBackendHerdrTarget                   [bool]
#   fm_backend_herdr_kill_serialized             Remove-FmBackendHerdrTargetSerialized         [bool]
#   -- native event push -------------------------------------------------------------------------------------------------
#   fm_backend_herdr_socket_path                 Get-FmBackendHerdrSocketPath                  socket path, or ''
#   fm_backend_herdr_events_capable              Test-FmBackendHerdrEventsCapable              [bool]
#   fm_backend_herdr_normalize_event             ConvertTo-FmBackendHerdrEventRecord           normalized record
#   fm_backend_herdr_event_reader_cmd            Get-FmBackendHerdrEventReaderCommand          [string[]] or @() = native
#   fm_backend_herdr_escalation_marker           Get-FmBackendHerdrEscalationMarker            marker path
#   fm_backend_herdr_apply_transition            Select-FmBackendHerdrTransition               record, or $null
#   fm_backend_herdr_commit_transition           Save-FmBackendHerdrTransition                 [bool]
#   fm_backend_herdr_clear_transition            Clear-FmBackendHerdrTransition                [bool]
#   fm_backend_herdr_wait_transition             Wait-FmBackendHerdrTransition                 @{Code;Record}
#
# NO SECOND ANSI STRIPPER. fm_backend_herdr_strip_ansi is a one-line pipe into
# fm_composer_strip_ansi, and bin/fm-composer-lib.psm1 already ships
# Get-FmComposerPlainText with identical semantics. A second copy here is exactly
# the drift this port exists to prevent, so every call site uses the shared
# owner - the same decision bin/fm-backend.psm1 recorded for fm_meta_get.
#
# GLOBALS ARE FOLDED INTO RETURN VALUES. The bash twin publishes secondary
# results in FM_BACKEND_HERDR_* shell globals for one reason: a caller that
# captures stdout runs the function in a SUBSHELL, where assignments cannot
# escape. PowerShell has no subshell boundary, so those values travel back in one
# hashtable and the globals are gone - the same collapse bin/fm-backend.psm1
# applied to FM_BACKEND_DETECTED and bin/fm-psproc-lib.psm1 to FM_NATIVE_PID_*.
# The complete mapping, for the entrypoint packages that consume them:
#
#   FM_BACKEND_HERDR_SESSION / _PANE                 -> @{Session;Pane}          (Get-FmBackendHerdrTarget)
#   FM_BACKEND_HERDR_LAUNCHER_{PANE,TAB,WORKSPACE}_ID-> @{Code;PaneId;TabId;WorkspaceId}
#   FM_BACKEND_HERDR_WS_ID / _WS_SEEDED_TAB_ID       -> @{Code;WorkspaceId;SeededTabId}
#   FM_BACKEND_HERDR_JOURNAL_*  (12 fields)          -> the snapshot hashtable
#   FM_BACKEND_HERDR_PROJECTION_*                    -> @{Ok;Session;WorkspaceId;SeededTabId;
#                                                         SeededPaneId;TabId;PaneId;CleanupSafe}
#   FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE    -> @{Code;AgentState}       (Close-FmBackendHerdrProjectionPane)
#   FM_BACKEND_HERDR_PI_*                            -> @{Found;Valid;OpenLine;Line;LastSeparatorLine;Content}
#
# ============================================================================
# THE FOUR DELIBERATE DIVERGENCES, each stated with its reason.
#
# 1. PANE BOOTSTRAP INVERTS TO A NO-OP (docs/powershell-port.md, "Windows-native
#    wins"). fm_backend_herdr_pane_posixify exists for exactly one reason: Herdr's
#    Windows build starts every pane in PowerShell, and the BASH tree then types
#    POSIX shell syntax into it (`treehouse get ...`, `export GOTMPDIR=...`, the
#    harness launch), so the pane has to be converted to Git bash first or the
#    spawn is corrupted. A PowerShell-native firstmate types PowerShell into a
#    PowerShell pane - `$env:GOTMPDIR = ...` instead of `export`, and treehouse
#    and git are native executables invoked identically either way - so the shell
#    the pane already runs is the shell the commands are written for, and there is
#    nothing to convert.
#
#    Initialize-FmBackendHerdrPaneShell is therefore a documented, always-$true
#    no-op rather than a deleted function: it keeps the pairing greppable, it
#    keeps the call sites structurally identical to the bash twin's, and it is the
#    one place to reverse the decision if it ever proves wrong.
#
#    THE CONTRACT THIS PLACES ON THE SPAWN PACKAGE, stated because it is a real
#    coupling and not an assumption anyone should have to re-derive: a PowerShell
#    caller of New-FmBackendHerdrTask MUST send PowerShell-syntax pane commands.
#    Nothing here can enforce that, but nothing here silently papers over it
#    either - Test-FmBackendHerdrPaneShellIsPowerShell is exported so fm-spawn.ps1
#    can assert the expectation rather than assume it. The bash tree is
#    unaffected: bin/fm-spawn.sh sources bin/backends/herdr.sh and still gets the
#    full Git-bash bootstrap with its loud refusal.
#
# 2. THE EVENT READER IS NATIVE, AND THE READER OVERRIDE STILL WORKS.
#    herdr-eventwait.py is absorbed (docs/powershell-port.md; inventory R5): .NET
#    reaches the same newline-delimited JSON stream directly, so there is no fifo,
#    no mkfifo, no `exec 9<`, no background reader process and no python3
#    dependency on the PowerShell path. FM_BACKEND_HERDR_EVENT_READER is still
#    honored and still spawns an external reader with the identical argv and
#    stdout contract, because it is the seam the event suites replay canned
#    streams through. See Wait-FmBackendHerdrTransition for the transport and for
#    the return-code trichotomy that IS the contract (R5: contract the output,
#    not the mechanism).
#
# 3. bin/backends/herdr-workspace-move.py IS KEPT AS A SUBPROCESS, NOT ABSORBED.
#    It sits behind a process boundary at all three call sites, the conventions
#    page names only herdr-eventwait.py as absorbed, and FM_BACKEND_HERDR_WORKSPACE_MOVER
#    is a test seam pointing at a replacement executable. Absorbing it would also
#    do something a port must not: the shipped helper uses socket.AF_UNIX, which
#    Python does not expose on Windows, so presentation ORDERING is inert on this
#    host in the bash world - a native PowerShell mover would silently switch it
#    on, which is a behavior change wearing a port's costume (inventory R6's
#    reasoning applied to a different file). Enabling it is worth doing
#    deliberately, as its own change, with its own evidence.
#
#    Windows execution detail: bash runs the helper through its shebang. .NET
#    cannot start a `.py` directly, so a mover path ending in `.py` is launched
#    through the resolved `python3` (then `python`); any other mover path is
#    executed directly, which is what keeps the test seam's own executables
#    working.
#
# 4. THE FM_BACKEND_HERDR_* KNOBS ARE READ PER CALL, NOT PINNED AT LOAD.
#    The bash twin binds FM_BACKEND_HERDR_COMPOSER_LINES and friends with
#    `${VAR:-default}` at SOURCE time. Reading them per call is identical for any
#    process that sets its environment before the first call - which is every real
#    firstmate process - and is required for the batched differential driver,
#    where one pwsh evaluates many cases and applies each case's environment in
#    turn. Same precedent and same argument as bin/fm-backend.psm1's divergence 1.
#
# ============================================================================
# WHAT IS FAITHFUL EVEN THOUGH POWERSHELL COULD DO BETTER
#
# * THE `ps` PROBES STAY EXTERNAL. Get-FmBackendHerdrPaneIdleShellSample and
#   Test-FmBackendHerdrBareShellPid run the same `$FM_HERDR_PS_BIN` (default `ps`)
#   with the same flags as the bash twin, and skip the OS-table no-child/sleep
#   cross-check on exactly the same failure. Reading the native process table
#   instead would make the PowerShell path STRICTER than the bash path on this
#   host - the twins would then disagree about the same pane - and it would break
#   FM_HERDR_PS_BIN, a documented test seam. Same reasoning as the `noacl`
#   private-file gates in docs/powershell-port.md.
# * THE LOCK PATH HASH IS BYTE-COMPATIBLE. Get-FmBackendHerdrPresentationSessionLockPath
#   hashes exactly `<session>\0<socket>` with SHA-256 and takes the first 32
#   lowercase hex characters, so a bash process and a PowerShell process contending
#   for the same named session derive the SAME lock file. A different spelling
#   would mean both believe they hold it (inventory R2's hazard, in this adapter).
# * TRAILING-NEWLINE CONVENTION. Every function whose bash twin is consumed
#   through `$( ... )` returns the value a bash caller ends up holding, i.e. with
#   trailing newlines already stripped. Get-FmBackendHerdrCapture matches its bash
#   twin exactly, which itself ends in `tail` over a `$( ... )`-stripped string and
#   therefore carries no trailing newline either - unlike the tmux adapter's.
# * LOCALE. Test-FmBackendHerdrPiSeparatorRow's minimum width is `${#row}`, which
#   bash measures in CHARACTERS under a UTF-8 locale and in BYTES under LC_ALL=C.
#   This host runs LANG=en_GB.UTF-8 (verified), so characters is the differential
#   oracle's own answer and is what this uses.
#
# WINDOWS VERIFICATION. Real herdr 0.7.5-preview (protocol 18) is installed on the
# reference host. The named-pipe event transport was verified live against an
# isolated `fm-lab-*` session: the pipe `\\.\pipe\<full windows sock path>` exists
# alongside the marker file, and a subscribe written BEFORE any read is answered
# with {"result":{"type":"subscription_started"}}. tests/fm-backend-herdr-psm1.test.sh
# is the differential authority; tests/fm-backend-herdr.test.sh remains the bash
# oracle it is diffed against.
#
# Imported through bin/fm-backend.psm1:
#   Import-FmBackendAdapter herdr

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports: a nested Import-Module -Force REMOVES the loaded
# module GLOBALLY first, which would strip a consumer of commands it had already
# imported (verified live; bin/fm-composer-lib.psm1 carries the same note).
#
# fm-wake-lib is imported UNCONDITIONALLY, where the bash twin lazily sources it
# inside fm_backend_herdr_kill behind a `declare -F fm_lock_try_acquire` probe.
# That probe exists because bash function names live in one shared shell scope; a
# .psm1 resolves names in its OWN scope and cannot see what its caller imported,
# so the undeclared dependency has to become a declared one (inventory R4).
Import-Module (Join-Path $PSScriptRoot '..' 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-composer-lib.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-transition-lib.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-wake-lib.psm1')

$script:FmHerdrOrdinal = [System.StringComparison]::Ordinal
$script:FmHerdrTab = "`t"

# The repo root this adapter resolves its sibling helpers from. The bash twin
# spells it FM_BACKEND_HERDR_ROOT and derives it from BASH_SOURCE; here the module
# knows its own directory, so the derivation cannot be broken by a caller's cwd.
$script:FmHerdrRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

# Protocol floors. The adapter's spawn/capture/send primitives work on 14; only
# the push subscriber needs 16, and workspace.move first appears in the
# protocol-16 schema.
$script:FmHerdrMinProtocol = 14
$script:FmHerdrMinEventsProtocol = 16
$script:FmHerdrMinWorkspaceMoveProtocol = 16

# Per-pane escalation dedupe marker prefix, under the state dir. One marker per
# window, keyed like the watcher's own .stale-<key>: set when a ->blocked edge is
# enqueued, cleared on any working edge, so exactly one wake fires per ->blocked
# edge and a reconnect level-reconcile never re-delivers a still-blocked pane.
$script:FmHerdrEscalatedPrefix = '.herdr-escalated-'

# .fm-secondmate-home is written by bin/fm-home-seed.sh at a seeded secondmate
# home's root, containing exactly that secondmate's id. The primary firstmate home
# never carries this marker.
$script:FmHerdrSecondmateMarker = '.fm-secondmate-home'

# The default-off presentation projection is intentionally separate from the
# authoritative task endpoint record. A per-task journal lives under state/ as
# <id>.herdr-presentation. Version 1 records only the attempted projection's
# random correlator; version 2 additionally binds the successful projection's
# exact home, session, workspace, tab, pane, parent, and presentation labels so a
# resumed spawn can replace one verified agent-free husk under the session lock.
# No send, capture, Treehouse, or general task-ownership path reads it.
$script:FmHerdrPresentationJournalSuffix = '.herdr-presentation'

# The recognized bare pane shells. Test-FmBackendHerdrBareShellPid's list is
# DELIBERATELY NARROWER than the idle-shell sample's: the sample accepts
# powershell/pwsh because that is what a Herdr Windows pane genuinely runs, while
# the signal-escalation gate does not, and the bash twin has exactly the same
# asymmetry. Widening the kill-side list here would let this adapter signal a
# process class the bash twin refuses to signal.
$script:FmHerdrKillableShells = [string[]]@('sh', 'bash', 'zsh', 'dash', 'ksh', 'fish')
$script:FmHerdrPaneShells = [string[]]@('sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'powershell', 'pwsh')

# --- small primitives ---------------------------------------------------------

<#
.SYNOPSIS
Sleep for a bash-style fractional-seconds string.
.DESCRIPTION
`sleep 0.05` and `sleep "$settle"` appear throughout the bash twin, where the
argument is a STRING that may be empty or non-numeric. bash's sleep errors and
the script continues; this parses invariantly and treats anything unparseable as
zero, which is the same observable outcome.
#>
function Start-FmBackendHerdrSleep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Start- is the natural verb for a sleep and keeps the pairing with the bash `sleep` call sites obvious, but this changes nothing outside its own scope. Under -WhatIf it would skip the wait and every submit-confirmation window would collapse to zero, which is worse than no confirmation surface at all.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds = '')

    $value = 0.0
    if (-not [string]::IsNullOrWhiteSpace($Seconds)) {
        if (-not [double]::TryParse($Seconds, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            $value = 0.0
        }
    }
    if ($value -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Round($value * 1000))
}

<#
.SYNOPSIS
An integer knob read from the environment with a bash `${VAR:-default}` fallback.
.DESCRIPTION
Divergence 4: read per call rather than pinned at load. A present-but-invalid
value falls back to the default, matching the `case "$v" in ''|*[!0-9]*)` guards
the bash twin writes around every one of these.
#>
function Get-FmBackendHerdrIntKnob {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][int]$Default
    )
    $raw = Get-FmEnv -Name $Name
    if ([string]::IsNullOrEmpty($raw)) { return $Default }
    $value = 0
    if (-not [int]::TryParse($raw, [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $Default
    }
    return $value
}

<#
.SYNOPSIS
True when the scripted-CLI test seam is active.
.DESCRIPTION
tests/fm-backend-herdr.test.sh replaces the herdr CLI with NUMBERED response
fixtures, so any extra CLI call the adapter makes would consume a fixture
scripted for a later call and derail the whole conversation. Only that suite sets
FM_BACKEND_HERDR_SCRIPTED_CLI=1; production and the real-herdr suites never do.
#>
function Test-FmBackendHerdrScriptedCli {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Get-FmEnv -Name 'FM_BACKEND_HERDR_SCRIPTED_CLI') -eq '1')
}

<#
.SYNOPSIS
The physical path of a directory, with every symlink resolved.
.DESCRIPTION
The `cd "$d" && pwd -P` twin. Two callers depend on it and both are
identity-critical: the canonical socket path feeds the presentation lock's hash,
and the projection home identity is written into the version 2 journal and
compared on every reclaim. `/tmp -> /private/tmp` on macOS is exactly the case
that makes one socket look like two locks, which is why the resolution is
component-wise rather than a leaf-only ResolveLinkTarget.

Returns $null when the directory does not exist, matching `cd` failing.
#>
function Get-FmBackendHerdrPhysicalDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.Directory]::Exists($native)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($native)
    } catch {
        return $null
    }
    if (Test-FmWindows) {
        # No component walk on Windows: MSYS `pwd -P` returns the drive path
        # unchanged for every location firstmate stores, and resolving reparse
        # points here could produce a spelling the bash twin never produces -
        # which would split one lock identity into two.
        return $full
    }
    $parts = $full.Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)
    $accum = [string][System.IO.Path]::DirectorySeparatorChar
    foreach ($part in $parts) {
        $accum = [System.IO.Path]::Combine($accum, $part)
        try {
            $target = [System.IO.Directory]::ResolveLinkTarget($accum, $true)
            if ($null -ne $target) { $accum = $target.FullName }
        } catch {
            # An unreadable component is left as written, exactly as `pwd -P`
            # leaves a path it cannot stat rather than inventing one.
            $null = $_
        }
    }
    return $accum
}

# --- the CLI ------------------------------------------------------------------

<#
.SYNOPSIS
Run `herdr <args...>` scoped to one named session.
.DESCRIPTION
Twin of fm_backend_herdr_cli. Sets BOTH the HERDR_SESSION environment variable
AND appends a trailing `--session <name>` flag, and the flag is the part that
matters: verified empirically (docs/herdr-backend.md "Session targeting") that on
the installed client the env var is NOT reliably honored by CLI subcommands once
ANY other herdr server is bound on the machine - queries silently fall back to
whatever server IS running, which is the wrong one. The env var is kept alongside
it: harmless, self-documenting, and forward-compatible.

Never used by Test-FmBackendHerdrVersion, which is intentionally
session-independent (it reads only .client.* fields).

Returns Invoke-FmTool's hashtable so a caller can branch on Ok, read StdOut, or
combine both streams the way the bash twin's `2>&1` sites do. HERDR_SESSION is
set on this process and restored in a finally block, because child processes
inherit the process environment - the same effect as bash's command prefix, and
the reason the restore has to distinguish "was empty" from "was unset".
#>
function Invoke-FmBackendHerdrCli {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @()
    )

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = 'herdr: command not found'; Ok = $false }
    }

    $argv = @($Arguments) + @('--session', $Session)
    $previous = [Environment]::GetEnvironmentVariable('HERDR_SESSION')
    try {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $Session)
        return Invoke-FmTool -FilePath $herdr.Source -Arguments $argv
    } finally {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $previous)
    }
}

<#
.SYNOPSIS
The combined stdout+stderr text of a CLI result, in that order.
.DESCRIPTION
Several classifiers read `$(fm_backend_herdr_cli ... 2>&1)` because a
business-logic "not found" is a NORMAL outcome there, not a call failure, and the
installed binary reports it on one stream or the other depending on version. This
is that `2>&1`.
#>
function Get-FmBackendHerdrCombinedOutput {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Result)
    return ([string]$Result.StdOut) + ([string]$Result.StdErr)
}

# --- JSON, in place of 97 jq invocations --------------------------------------
#
# jq semantics that had to be reproduced exactly, because the bash twin leans on
# all four:
#   `// empty`   -> null, false and MISSING all collapse to "no value", which is
#                   an empty string once `$( ... )` captures it.
#   `jq -r`      -> raw output, so a JSON string arrives without quotes. Every
#                   `-r` site here is a string or a number.
#   `jq -er`     -> additionally FAILS when the result is null/false/empty, which
#                   the bash twin uses as a guard (`|| return 1`).
#   `2>/dev/null`-> a parse failure is silently "no value", never an error. Every
#                   accessor below returns $null on unparseable input for exactly
#                   that reason.

<#
.SYNOPSIS
Parse one herdr JSON response, or $null when it is not parseable.
.DESCRIPTION
The `printf '%s' "$out" | jq ... 2>/dev/null` twin: unparseable input is not an
error, it is simply no value. -AsHashtable keeps every object a plain
IDictionary, so a missing key is a ContainsKey miss rather than a StrictMode
property violation.
#>
function ConvertFrom-FmBackendHerdrJson {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 64
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
Walk a dotted path through a parsed JSON document.
.DESCRIPTION
The `.a.b.c` twin. Any missing key, any non-dictionary on the way down, and any
null yields $null - which is what `// empty` then turns into an empty string.
#>
function Get-FmBackendHerdrJsonValue {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$Path
    )

    $node = $Document
    foreach ($key in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -isnot [System.Collections.IDictionary]) { return $null }
        if (-not $node.Contains($key)) { return $null }
        $node = $node[$key]
    }
    # A bare `return $node` DESTROYS array-ness: PowerShell unrolls the output
    # stream, so an empty JSON array comes back as $null and a single-element
    # array comes back as the bare element. Both then fail an `-is [array]`
    # test, which is exactly what jq's `(.f | type) == "array"` must accept.
    # The comma operator wraps the array so assignment unrolls back to it.
    # Non-array values must NOT be wrapped, or every scalar becomes an array.
    if ($node -is [System.Array] -or $node -is [System.Collections.IList]) { return , $node }
    return $node
}

<#
.SYNOPSIS
A dotted-path lookup rendered as jq -r '... // empty' would render it.
.DESCRIPTION
Strings come back verbatim; a number comes back in its invariant form; null,
false, a missing key and an unparseable document all come back as ''. That last
collapse is not laziness - it is what makes every `[ -n "$x" ]` guard in the bash
twin mean the same thing here.
#>
function Get-FmBackendHerdrJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$Path
    )

    $value = Get-FmBackendHerdrJsonValue -Document $Document -Path $Path
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { if ($value) { return 'true' } return '' }
    if ($value -is [string]) { return $value }
    if ($value -is [System.Collections.IDictionary] -or $value -is [System.Array]) { return '' }
    return [string]([System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture))
}

<#
.SYNOPSIS
A JSON array as a plain object list, or @() when it is not an array.
.DESCRIPTION
Every `(.result.x | type) == "array"` guard in the bash twin exists because a
response that changed shape must not be read as an empty list. Callers that need
that distinction use Test-FmBackendHerdrJsonArray; callers that only need to
iterate use this.
#>
function Get-FmBackendHerdrJsonArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$Path
    )

    $value = Get-FmBackendHerdrJsonValue -Document $Document -Path $Path
    if ($null -eq $value) { return @() }
    if ($value -isnot [System.Array] -and $value -isnot [System.Collections.IList]) { return @() }
    return @($value)
}

<#
.SYNOPSIS
True only when the dotted path names a real JSON array.
#>
function Test-FmBackendHerdrJsonArray {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$Path
    )

    $value = Get-FmBackendHerdrJsonValue -Document $Document -Path $Path
    if ($null -eq $value) { return $false }
    return ($value -is [System.Array] -or $value -is [System.Collections.IList])
}

<#
.SYNOPSIS
One string field of a JSON object, as `select((.f|type)=="string" and (.f|length)>0)` reads it.
#>
function Get-FmBackendHerdrItemString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Item,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    if ($null -eq $Item) { return '' }
    if ($Item -isnot [System.Collections.IDictionary]) { return '' }
    if (-not $Item.Contains($Key)) { return '' }
    $value = $Item[$Key]
    if ($value -isnot [string]) { return '' }
    return $value
}

<#
.SYNOPSIS
True when a JSON object's boolean field is exactly true.
#>
function Test-FmBackendHerdrItemTrue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Item,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    if ($null -eq $Item) { return $false }
    if ($Item -isnot [System.Collections.IDictionary]) { return $false }
    if (-not $Item.Contains($Key)) { return $false }
    return ($Item[$Key] -is [bool] -and [bool]$Item[$Key])
}

# --- tooling, version, session ------------------------------------------------

<#
.SYNOPSIS
Refuse loudly when herdr is missing.
.DESCRIPTION
Twin of fm_backend_herdr_tool_check, minus the jq half. jq is a required tool for
the BASH adapter because that is how it parses herdr's JSON; the PowerShell
adapter parses JSON in process and genuinely does not need it, so demanding it
would refuse a working PowerShell host for a dependency it never uses.

The dependency is not silently dropped fleet-wide: bin/fm-backend.psm1's
Get-FmBackendRequiredTool still reports `herdr jq treehouse` byte-identically to
its bash twin, so bootstrap and spawn still gate on jq while the bash tree can
still read the same records.
#>
function Test-FmBackendHerdrTool {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmCommand 'herdr')) {
        Write-FmErr "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev) (dual-licensed AGPL-3.0-or-later/commercial)"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Refuse loudly on a missing or protocol-incompatible herdr client.
.DESCRIPTION
Twin of fm_backend_herdr_version_check. Reads `herdr status --json`'s .client.*
fields, which are session-independent - unlike .server - so this deliberately
does NOT go through Invoke-FmBackendHerdrCli and never names a session.
#>
function Test-FmBackendHerdrVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmBackendHerdrTool)) { return $false }

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return $false }
    $result = Invoke-FmTool -FilePath $herdr.Source -Arguments @('status', '--json')
    if (-not $result.Ok) {
        Write-FmErr "error: 'herdr status --json' failed; is herdr installed correctly?"
        return $false
    }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    $protocol = Get-FmBackendHerdrJsonString $doc @('client', 'protocol')
    $version = Get-FmBackendHerdrJsonString $doc @('client', 'version')

    $value = 0
    if ([string]::IsNullOrEmpty($protocol) -or
        -not [int]::TryParse($protocol, [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        Write-FmErr 'error: could not read herdr client protocol from ''herdr status --json''; refusing to use an unverified herdr build'
        return $false
    }
    if ($value -lt $script:FmHerdrMinProtocol) {
        $shown = if ([string]::IsNullOrEmpty($version)) { 'unknown' } else { $version }
        Write-FmErr "error: herdr protocol $value (version $shown) is older than the verified minimum $($script:FmHerdrMinProtocol); update herdr (herdr update) before using backend=herdr"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Which named herdr session this normal spawn/op uses.
.DESCRIPTION
Twin of fm_backend_herdr_session. HERDR_SESSION mirrors tmux's $TMUX ambient
selection; absent means herdr's own "default" session. Do NOT use HERDR_SESSION
alone for destructive test cleanup - bin/fm-herdr-lab.sh owns that path.
#>
function Get-FmBackendHerdrSession {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'HERDR_SESSION' -Default 'default')
}

<#
.SYNOPSIS
This firstmate HOME's own herdr workspace label.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_label. The PRIMARY home (no secondmate marker)
resolves to the constant "firstmate", byte-identical to every pre-existing task's
recorded label - no forced migration. A SECONDMATE home resolves to
"2ndmate-<secondmate-id>". Read fresh from FM_HOME on every call rather than
cached, because FM_HOME is the home's own durable identity, which makes the label
automatically stable across every respawn and recovery for the life of that home.

`tr -d '[:space:]'` is byte-oriented in the bash twin; the six ASCII members of
the C-locale space class are what it deletes, so that is what is stripped here.
#>
function Get-FmBackendHerdrWorkspaceLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $context = Get-FmContext $PSScriptRoot
    $marker = Join-Path $context.Home $script:FmHerdrSecondmateMarker
    $native = ConvertTo-FmNativePath $marker
    if ([System.IO.File]::Exists($native)) {
        $raw = Get-FmFileText $native
        $id = ($raw -replace '[\t\n\v\f\r ]', '')
        if (-not [string]::IsNullOrEmpty($id)) { return "2ndmate-$id" }
    }
    return 'firstmate'
}

<#
.SYNOPSIS
Split "<session>:<pane-id>" on the FIRST colon only.
.DESCRIPTION
Twin of fm_backend_herdr_parse_target, whose two shell globals become this
hashtable. A herdr pane id CONTAINS a colon ("w1:p2"), so the session is always
the first field and the remainder is the whole pane id. Returns $null when either
half is empty or when there was no colon at all.
#>
function Get-FmBackendHerdrTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if ([string]::IsNullOrEmpty($Target)) { return $null }
    $colon = $Target.IndexOf(':')
    if ($colon -lt 0) { return $null }
    $session = $Target.Substring(0, $colon)
    $pane = $Target.Substring($colon + 1)
    if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($pane)) { return $null }
    return @{ Session = $session; Pane = $pane }
}

<#
.SYNOPSIS
Parse a target and make sure its named server is up.
.DESCRIPTION
Twin of fm_backend_herdr_target_ready. Returns the parsed target on success and
$null when the target is malformed or the server could not be started.
#>
function Test-FmBackendHerdrTargetReady {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) { return $null }
    if (-not (Initialize-FmBackendHerdrServer $parsed.Session)) { return $null }
    return $parsed
}

<#
.SYNOPSIS
Start the named herdr server headless if it is not already running.
.DESCRIPTION
Twin of fm_backend_herdr_server_ensure, mirroring tmux's `has-session ||
new-session -d`. Verified: a bare socket CLI call does NOT auto-start the server,
so this must run before any workspace/tab/pane call. The launch is detached and
the readiness poll is bounded at 10s, exactly as the bash twin's
`( ... & )` plus 20 half-second polls.
#>
function Initialize-FmBackendHerdrServer {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session)

    if ((Get-FmBackendHerdrServerRunning $Session) -eq 'true') { return $true }

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return $false }

    # Detached, output discarded: the bash twin backgrounds it inside a subshell
    # so the server outlives this call and never inherits its streams.
    $previous = [Environment]::GetEnvironmentVariable('HERDR_SESSION')
    try {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $Session)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $herdr.Source
        foreach ($a in @('server', '--session', $Session)) { [void]$psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $proc.Dispose()
    } catch {
        return $false
    } finally {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $previous)
    }

    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-FmBackendHerdrServerRunning $Session) -eq 'true') { return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-FmErr "error: herdr server for session '$Session' did not report running within 10s"
    return $false
}

<#
.SYNOPSIS
The named session's `.server.running` field as a raw string.
.DESCRIPTION
`jq -r '.server.running // false'`, so an unreadable status answers 'false' and a
running server answers 'true'.
#>
function Get-FmBackendHerdrServerRunning {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session)

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('status', '--json')
    if (-not $result.Ok) { return 'false' }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    $value = Get-FmBackendHerdrJsonValue -Document $doc -Path @('server', 'running')
    if ($value -is [bool] -and [bool]$value) { return 'true' }
    return 'false'
}

# --- host path normalization --------------------------------------------------

<#
.SYNOPSIS
Translate a host-native path reported by herdr into MSYS/POSIX comparison form.
.DESCRIPTION
Twin of fm_backend_herdr_normalize_host_path. Herdr's Windows build reports
Windows drive paths ("F:\proj\x" or "F:/proj/x") while the durable records this is
compared against are MSYS-form absolutes ("/f/proj/x"). Unix herdr never reports a
drive-letter path, so the pattern guard keeps this a byte-identical pass-through
off Windows - which is why the conversion is applied ONLY to a drive-shaped path
here, exactly as the bash `case` does, rather than to everything.
#>
function ConvertTo-FmBackendHerdrHostPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path -match '^[A-Za-z]:[\\/]') { return (ConvertTo-FmPosixPath $Path) }
    return $Path
}

<#
.SYNOPSIS
Normalize one absolute socket path so two spellings of the same socket compare equal.
.DESCRIPTION
Twin of fm_backend_herdr_canonical_socket_path, and the SINGLE owner of every
socket-identity comparison in this adapter - the presentation session lock and the
launcher-identity same-session proof both use it, so they cannot drift.

Refuses a relative or empty path. An unresolvable directory is left as written
rather than treated as a failure, so a socket whose directory was removed still
compares by its own literal path.
#>
function Get-FmBackendHerdrCanonicalSocketPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Socket = '')

    if ([string]::IsNullOrEmpty($Socket)) { return $null }
    $path = ConvertTo-FmBackendHerdrHostPath $Socket
    if (-not $path.StartsWith('/')) { return $null }

    $slash = $path.LastIndexOf('/')
    $dir = if ($slash -le 0) { '/' } else { $path.Substring(0, $slash) }
    $base = $path.Substring($slash + 1)
    if ([string]::IsNullOrEmpty($dir) -or [string]::IsNullOrEmpty($base)) { return $null }

    $physical = Get-FmBackendHerdrPhysicalDirectory $dir
    if ($null -ne $physical) {
        $dir = ConvertTo-FmPosixPath $physical
        return "$dir/$base"
    }
    return $path
}

# --- the presentation journal -------------------------------------------------

<#
.SYNOPSIS
Generate a compact 128-bit base64url token.
.DESCRIPTION
Twin of fm_backend_herdr_projection_id. The token is a NON-ADVERSARIAL VISUAL
CORRELATOR and never destructive authority - it is visible in a workspace title
only because Herdr exposes no verified hidden persistent field. 16 random bytes
base64-encode to 24 characters with two '=' pads, so the stripped result is
exactly 22 characters from the base64url alphabet, which the same guards the bash
twin applies re-check here.
#>
function New-FmBackendHerdrProjectionId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'New- is the natural verb for a generator and keeps the pairing with fm_backend_herdr_projection_id greppable, but this only formats 16 random bytes and touches nothing outside its own scope. Under -WhatIf it would return nothing and every caller would treat that as a generation failure.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $bytes = [byte[]]::new(16)
    try {
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    } catch {
        return $null
    }
    $token = [System.Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').Replace('=', '')
    if ($token.Length -ne 22) { return $null }
    if ($token -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    return $token
}

<#
.SYNOPSIS
The per-task presentation journal path under a state directory.
#>
function Get-FmBackendHerdrProjectionJournalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )
    return "$StateDir/$TaskId$($script:FmHerdrPresentationJournalSuffix)"
}

<#
.SYNOPSIS
Atomically publish the version 1 attempt journal before any projected create.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_create. The bash twin gets
create-if-absent semantics from a hard link in the same directory, so two
concurrent attempts cannot overwrite each other's token; FileMode.CreateNew is
the same atomic claim (docs/powershell-port.md names it as the noclobber twin) and
publishes the identical three-line record.

The 0600 mode the bash twin sets is applied where the platform has one and
skipped where it does not, which is also where it is inert - no gate anywhere
reads this file's mode, only that it is a regular non-symlink file.

Returns the token, or $null after writing the same refusal.
#>
function New-FmBackendHerdrProjectionJournal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin publishes unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )

    if ([string]::IsNullOrEmpty($TaskId) -or $TaskId.StartsWith('.') -or $TaskId -notmatch '^[A-Za-z0-9._-]+$') {
        Write-FmErr 'error: invalid task id for herdr presentation journal'
        return $null
    }
    $stateNative = ConvertTo-FmNativePath $StateDir
    try {
        [void][System.IO.Directory]::CreateDirectory($stateNative)
    } catch {
        return $null
    }

    $journal = Get-FmBackendHerdrProjectionJournalPath -StateDir $StateDir -TaskId $TaskId
    $native = ConvertTo-FmNativePath $journal
    if ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native)) {
        Write-FmErr "error: herdr presentation journal already exists for $TaskId; refusing a concurrent or repeated projected create"
        return $null
    }

    $token = New-FmBackendHerdrProjectionId
    if ([string]::IsNullOrEmpty($token)) {
        Write-FmErr 'error: could not generate a 128-bit herdr presentation projection id'
        return $null
    }

    $body = "version=1`ntask_id=$TaskId`nprojection_id=$token`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($body)
    try {
        $stream = [System.IO.File]::Open($native, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    } catch {
        Write-FmErr "error: herdr presentation journal appeared concurrently for $TaskId; refusing projected create"
        return $null
    }
    Set-FmBackendHerdrPrivateFileMode $native
    return $token
}

<#
.SYNOPSIS
Apply owner-only permissions where the platform has them.
.DESCRIPTION
The `chmod 0600` twin. On Windows this throws PlatformNotSupportedException and
is skipped, which is exactly what chmod does there - inert (docs/powershell-port.md
"the noacl private-file gates"). Enforcing real ACLs instead would make the
PowerShell path produce artifacts the bash path does not, so it deliberately does
not.
#>
function Set-FmBackendHerdrPrivateFileMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin chmods unconditionally; a confirmation surface would diverge from the twin.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    try {
        [System.IO.File]::SetUnixFileMode($Path,
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
    } catch {
        $null = $_
    }
}

<#
.SYNOPSIS
Read one journal field that must appear EXACTLY once.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_field: `grep -c "^key="` must be 1,
then the value is everything after the first '='. The exactly-once rule is the
point - a duplicated key is a malformed journal, not a last-wins record, which is
the opposite of how state/<id>.meta is read.
#>
function Get-FmBackendHerdrProjectionJournalField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Journal,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    $prefix = "$Key="
    $found = $null
    $count = 0
    foreach ($line in (Get-FmFileLines $Journal)) {
        if ($line.StartsWith($prefix, $script:FmHerdrOrdinal)) {
            $count++
            $found = $line.Substring($prefix.Length)
        }
    }
    if ($count -ne 1) { return $null }
    return $found
}

<#
.SYNOPSIS
Validate a version 1 attempt journal or a version 2 exact projection binding.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_snapshot, whose twelve shell globals
become this hashtable. Returns $null for anything that does not validate; a
caller must never treat a partial read as a binding.

The line-count gate (3 for version 1, 12 for version 2) is deliberate and is
carried over exactly: it is what stops a version 1 journal with extra lines
appended, or a truncated version 2 write, from being read as a valid binding.
#>
function Get-FmBackendHerdrProjectionJournalSnapshot {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Journal,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )

    $native = ConvertTo-FmNativePath $Journal
    if (-not [System.IO.File]::Exists($native)) { return $null }
    if (Test-FmSymlink $native) { return $null }

    # `wc -l` counts NEWLINES, so a well-formed record ending in "\n" reports its
    # line count and a truncated final line is not counted at all.
    $text = Get-FmFileText $native
    $lineCount = 0
    foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`n") { $lineCount++ } }

    $version = Get-FmBackendHerdrProjectionJournalField -Journal $Journal -Key 'version'
    if ($null -eq $version) { return $null }
    $journalTask = Get-FmBackendHerdrProjectionJournalField -Journal $Journal -Key 'task_id'
    if ($null -eq $journalTask) { return $null }
    $token = Get-FmBackendHerdrProjectionJournalField -Journal $Journal -Key 'projection_id'
    if ($null -eq $token) { return $null }
    if ($journalTask -cne $TaskId) { return $null }
    if ($token.Length -ne 22) { return $null }
    if ($token -notmatch '^[A-Za-z0-9_-]+$') { return $null }

    $snapshot = @{
        Version           = $version
        TaskId            = $journalTask
        ProjectionId      = $token
        Home              = ''
        Session           = ''
        WorkspaceId       = ''
        TabId             = ''
        PaneId            = ''
        ParentWorkspaceId = ''
        ParentLabel       = ''
        WorkspaceLabel    = ''
        TaskLabel         = ''
    }

    if ($version -ceq '1' -and $lineCount -eq 3) { return $snapshot }
    if (-not ($version -ceq '2' -and $lineCount -eq 12)) { return $null }

    $map = @{
        Home              = 'home'
        Session           = 'session'
        WorkspaceId       = 'workspace_id'
        TabId             = 'tab_id'
        PaneId            = 'pane_id'
        ParentWorkspaceId = 'parent_workspace_id'
        ParentLabel       = 'parent_label'
        WorkspaceLabel    = 'workspace_label'
        TaskLabel         = 'task_label'
    }
    foreach ($field in $map.Keys) {
        $value = Get-FmBackendHerdrProjectionJournalField -Journal $Journal -Key $map[$field]
        if ($null -eq $value) { return $null }
        $snapshot[$field] = $value
    }

    if (-not $snapshot.Home.StartsWith('/')) { return $null }
    foreach ($exact in @($snapshot.Session, $snapshot.WorkspaceId, $snapshot.TabId,
            $snapshot.PaneId, $snapshot.ParentWorkspaceId)) {
        if ([string]::IsNullOrEmpty($exact)) { return $null }
        if ($exact -match '\s') { return $null }
    }
    if ([string]::IsNullOrEmpty($snapshot.ParentLabel) -or
        [string]::IsNullOrEmpty($snapshot.WorkspaceLabel) -or
        [string]::IsNullOrEmpty($snapshot.TaskLabel)) {
        return $null
    }

    $expectedLabel = Get-FmBackendHerdrProjectionWorkspaceLabel -TaskId $TaskId -ProjectionId $snapshot.ProjectionId
    if ($snapshot.WorkspaceLabel -cne $expectedLabel) { return $null }
    if ($snapshot.TaskLabel -cne "fm-$TaskId") { return $null }
    return $snapshot
}

<#
.SYNOPSIS
Validate and read either journal version's non-authoritative visual correlator.
#>
function Get-FmBackendHerdrProjectionJournalToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Journal,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )

    $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $Journal -TaskId $TaskId
    if ($null -eq $snapshot) { return $null }
    return $snapshot.ProjectionId
}

<#
.SYNOPSIS
The canonical physical identity of a firstmate home, for the version 2 binding.
.DESCRIPTION
Twin of fm_backend_herdr_projection_home_identity. Written into the journal in
POSIX form and compared byte-for-byte on every reclaim, which is what makes a
cross-home binding detectable rather than merely unlikely.
#>
function Get-FmBackendHerdrProjectionHomeIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$FmHome = '')

    $physical = Get-FmBackendHerdrPhysicalDirectory $FmHome
    if ($null -eq $physical) { return $null }
    return (ConvertTo-FmPosixPath $physical)
}

<#
.SYNOPSIS
Write the twelve-field version 2 binding over an existing journal, atomically.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_write_v2. The pre-rename check that
the destination is still a regular non-symlink file is carried over: it is what
stops a journal that was replaced by a directory or a link between validation and
publication from being written through.
#>
function Write-FmBackendHerdrProjectionJournalV2 {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FmHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentWorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskLabel
    )

    $native = ConvertTo-FmNativePath $Journal
    if (-not [System.IO.File]::Exists($native)) { return $false }
    if (Test-FmSymlink $native) { return $false }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("version=2`n")
    [void]$sb.Append("task_id=$TaskId`n")
    [void]$sb.Append("projection_id=$Token`n")
    [void]$sb.Append("home=$FmHome`n")
    [void]$sb.Append("session=$Session`n")
    [void]$sb.Append("workspace_id=$WorkspaceId`n")
    [void]$sb.Append("tab_id=$TabId`n")
    [void]$sb.Append("pane_id=$PaneId`n")
    [void]$sb.Append("parent_workspace_id=$ParentWorkspaceId`n")
    [void]$sb.Append("parent_label=$ParentLabel`n")
    [void]$sb.Append("workspace_label=$WorkspaceLabel`n")
    [void]$sb.Append("task_label=$TaskLabel`n")

    if (-not (Set-FmFileTextAtomic -Path $native -Text $sb.ToString() -NoNewline)) { return $false }
    Set-FmBackendHerdrPrivateFileMode $native
    return $true
}

<#
.SYNOPSIS
Upgrade one exact version 1 attempt to a version 2 binding.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_bind. Refuses anything that is not
currently a valid version 1 attempt, so a second bind can never overwrite an
existing binding with different ids.
#>
function Set-FmBackendHerdrProjectionJournalBinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin publishes unconditionally; a confirmation surface would diverge from the twin and could leave a projection unbound.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FmHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentWorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskLabel
    )

    $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $Journal -TaskId $TaskId
    if ($null -eq $snapshot) { return $false }
    if ($snapshot.Version -cne '1') { return $false }

    return (Write-FmBackendHerdrProjectionJournalV2 -Journal $Journal -TaskId $TaskId `
            -Token $snapshot.ProjectionId -FmHome $FmHome -Session $Session `
            -WorkspaceId $WorkspaceId -TabId $TabId -PaneId $PaneId `
            -ParentWorkspaceId $ParentWorkspaceId -ParentLabel $ParentLabel `
            -WorkspaceLabel $WorkspaceLabel -TaskLabel $TaskLabel)
}

<#
.SYNOPSIS
Atomically advance one exact version 2 binding to a replacement endpoint.
.DESCRIPTION
Twin of fm_backend_herdr_projection_journal_replace_endpoint. The old tab and pane
must match the binding EXACTLY before it advances, so a reclaim whose husk moved
under it cannot publish a binding to something it never verified.
#>
function Update-FmBackendHerdrProjectionJournalEndpoint {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin publishes unconditionally; a confirmation surface would diverge from the twin and could strand a reclaimed projection.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OldTabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OldPaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewTabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewPaneId
    )

    $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $Journal -TaskId $TaskId
    if ($null -eq $snapshot) { return $false }
    if ($snapshot.Version -cne '2') { return $false }
    if ($snapshot.TabId -cne $OldTabId -or $snapshot.PaneId -cne $OldPaneId) { return $false }

    return (Write-FmBackendHerdrProjectionJournalV2 -Journal $Journal -TaskId $TaskId `
            -Token $snapshot.ProjectionId -FmHome $snapshot.Home -Session $snapshot.Session `
            -WorkspaceId $snapshot.WorkspaceId -TabId $NewTabId -PaneId $NewPaneId `
            -ParentWorkspaceId $snapshot.ParentWorkspaceId -ParentLabel $snapshot.ParentLabel `
            -WorkspaceLabel $snapshot.WorkspaceLabel -TaskLabel $snapshot.TaskLabel)
}

<#
.SYNOPSIS
Strip redundant owner prefixes from a task id used in a presentation label.
.DESCRIPTION
Twin of fm_backend_herdr_projection_concise_task_label. Presentation only: the
ordinary task tab stays fm-<id> and is NOT built by this helper.
#>
function Get-FmBackendHerdrProjectionConciseTaskLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$TaskId = '')

    $task = if ($null -eq $TaskId) { '' } else { $TaskId }
    if ($task.StartsWith('firstmate/', $script:FmHerdrOrdinal)) {
        $task = $task.Substring('firstmate/'.Length)
    } elseif ($task -cmatch '^2ndmate-') {
        # `${task#*/}` - the shortest leading match up to the FIRST slash - and
        # only when the id actually has one, matching the `2ndmate-*/*` pattern.
        $slash = $task.IndexOf('/')
        if ($slash -ge 0) { $task = $task.Substring($slash + 1) }
    }
    if ($task.StartsWith('fm-', $script:FmHerdrOrdinal)) { $task = $task.Substring(3) }
    return $task
}

<#
.SYNOPSIS
The presentation-only child workspace label.
.DESCRIPTION
Twin of fm_backend_herdr_projection_workspace_label. Literal U+2514 BOX DRAWINGS
LIGHT UP AND RIGHT, one space, the concise task label, then the unchanged
` · p:<full-22-char-token>` suffix. Labels and tokens remain non-authoritative
correlators only.
#>
function Get-FmBackendHerdrProjectionWorkspaceLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$TaskId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ProjectionId = ''
    )
    return "$([char]0x2514) $(Get-FmBackendHerdrProjectionConciseTaskLabel $TaskId) $([char]0x00B7) p:$ProjectionId"
}

# --- the machine-private per-session presentation lock ------------------------

<#
.SYNOPSIS
The one machine-private lock namespace, shared by every home using a session.
.DESCRIPTION
Twin of fm_backend_herdr_presentation_lock_namespace. Deliberately NOT under any
one home's state/: the lock serializes homes against each other, and a secondmate
must never have to write the primary home to take it.
#>
function Get-FmBackendHerdrPresentationLockNamespace {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return '/tmp/firstmate-herdr-presentation'
}

<#
.SYNOPSIS
A directory's octal permission bits, through the same `stat` the bash twin uses.
.DESCRIPTION
Twin of fm_backend_herdr_presentation_lock_namespace_mode. Kept as an external
call rather than a .NET UnixFileMode read so the two worlds get the same answer
from the same source on the same host - including the answer they get when stat
is unavailable, which is none.
#>
function Get-FmBackendHerdrPresentationLockNamespaceMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return (Invoke-FmBackendHerdrStat -Path $Path -DarwinFormat '%Lp' -GnuFormat '%a')
}

<#
.SYNOPSIS
A directory's owning uid, through the same `stat` the bash twin uses.
#>
function Get-FmBackendHerdrPresentationLockNamespaceUid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return (Invoke-FmBackendHerdrStat -Path $Path -DarwinFormat '%u' -GnuFormat '%u')
}

<#
.SYNOPSIS
Run `stat` with the BSD or GNU format string, as the platform requires.
.DESCRIPTION
The bash twin picks by `uname -s` = Darwin; this picks by the runtime's own
platform, which is the same question answered without a child process. The stat
call itself stays external. The path is passed in POSIX form because on Windows
the only `stat` available is MSYS's, which cannot resolve a drive path.
#>
function Invoke-FmBackendHerdrStat {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DarwinFormat,
        [Parameter(Mandatory)][string]$GnuFormat
    )

    $stat = Get-Command 'stat' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stat) { return $null }
    $statArgs = if ($IsMacOS) { @('-f', $DarwinFormat, (ConvertTo-FmPosixPath $Path)) }
    else { @('-c', $GnuFormat, (ConvertTo-FmPosixPath $Path)) }
    $result = Invoke-FmTool -FilePath $stat.Source -Arguments $statArgs
    if (-not $result.Ok) { return $null }
    return $result.StdOut.Trim()
}

<#
.SYNOPSIS
Is the lock namespace directory safe to hold this machine's session locks?
.DESCRIPTION
Twin of fm_backend_herdr_presentation_lock_namespace_valid. Three gates, in the
same order and with the same Windows carve-out:

  shape      - a real directory, not a symlink. Always enforced.
  ownership  - owned by this user. Enforced through the same id/stat pair the
               bash twin uses.
  mode 0700  - enforced everywhere it is satisfiable. On Windows Git Bash mounts
               /tmp noacl,posix=0,usertemp (verified live), so mkdir -m 700 and
               chmod are no-ops and every directory reads 755 - the gate is
               unsatisfiable AND unnecessary there, because that mount IS the
               per-user AppData\Local\Temp, already private at the NTFS ACL
               layer, so the shared-/tmp squatter threat it defends against
               cannot arise. The bash twin carves Windows out for exactly this
               reason and so does this.

When `id` or `stat` cannot be resolved at all - a PowerShell host with no MSYS on
PATH - the ownership gate degrades to the same Windows carve-out rather than
being replaced with an ACL check. An ACL check would be STRONGER than what the
bash twin does on this host, and the two worlds would then disagree about the
same directory (docs/powershell-port.md, "the noacl private-file gates").
#>
function Test-FmBackendHerdrPresentationLockNamespace {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.Directory]::Exists($native)) { return $false }
    if (Test-FmSymlink $native) { return $false }

    $expectedUid = Get-FmBackendHerdrCurrentUid
    $owner = Get-FmBackendHerdrPresentationLockNamespaceUid $native
    $mode = Get-FmBackendHerdrPresentationLockNamespaceMode $native

    if ([string]::IsNullOrEmpty($expectedUid) -or [string]::IsNullOrEmpty($owner) -or [string]::IsNullOrEmpty($mode)) {
        # The tools the bash twin reads are unavailable. See the description.
        return (Test-FmWindows)
    }
    if ($owner -cne $expectedUid) { return $false }
    if ($mode -ceq '700') { return $true }
    return (Test-FmWindows)
}

<#
.SYNOPSIS
This user's uid, through the same `id -u` the bash twin uses.
#>
function Get-FmBackendHerdrCurrentUid {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $id = Get-Command 'id' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $id) { return $null }
    $result = Invoke-FmTool -FilePath $id.Source -Arguments @('-u')
    if (-not $result.Ok) { return $null }
    return $result.StdOut.Trim()
}

<#
.SYNOPSIS
The one verified running socket path for a named session, canonicalized.
.DESCRIPTION
Twin of fm_backend_herdr_presentation_session_socket_path. Requires EXACTLY one
running session by that name whose socket_path is a non-empty JSON string - the
bash twin uses `jq` without `-r` precisely so a JSON null cannot become the
literal string "null", and the same type check is what this reproduces.
#>
function Get-FmBackendHerdrPresentationSessionSocketPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    if ([string]::IsNullOrEmpty($Session)) { return $null }
    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('session', 'list', '--json')
    if (-not $result.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut

    $matched = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('sessions'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'name') -cne $Session) { continue }
        if (-not (Test-FmBackendHerdrItemTrue -Item $item -Key 'running')) { continue }
        $socket = Get-FmBackendHerdrItemString -Item $item -Key 'socket_path'
        if ([string]::IsNullOrEmpty($socket)) { continue }
        $matched += $socket
    }
    if ($matched.Count -ne 1) { return $null }
    return (Get-FmBackendHerdrCanonicalSocketPath $matched[0])
}

<#
.SYNOPSIS
The machine-private lock path for one live named session/socket.
.DESCRIPTION
Twin of fm_backend_herdr_presentation_session_lock_path.

THE HASH IS A CROSS-RUNTIME CONTRACT, not an implementation detail. A bash
firstmate and a PowerShell firstmate can contend for the same named session
during the transition, and if the two derived different lock paths BOTH would
believe they hold the lock - the singleton silently stops being a singleton
(docs/powershell-port-inventory.md R2, in this adapter). So the digest input is
byte-identical to the bash twin's `printf '%s\0%s' "$session" "$socket"`: the
session, one NUL, the socket, no trailing newline; SHA-256; the first 32
characters of the LOWERCASE hex digest, exactly as shasum/sha256sum print it.
#>
function Get-FmBackendHerdrSessionLockKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Socket
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $bytes.AddRange($encoding.GetBytes($Session))
    $bytes.Add(0)
    $bytes.AddRange($encoding.GetBytes($Socket))
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes.ToArray())
    return [System.Convert]::ToHexString($digest).ToLowerInvariant().Substring(0, 32)
}

function Get-FmBackendHerdrPresentationSessionLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    if ([string]::IsNullOrEmpty($Session)) { return $null }
    $socket = Get-FmBackendHerdrPresentationSessionSocketPath $Session
    if ([string]::IsNullOrEmpty($socket)) { return $null }

    $key = Get-FmBackendHerdrSessionLockKey -Session $Session -Socket $socket

    $dir = Get-FmBackendHerdrPresentationLockNamespace
    $native = ConvertTo-FmNativePath $dir
    if (-not [System.IO.Directory]::Exists($native) -and -not [System.IO.File]::Exists($native)) {
        try {
            [void][System.IO.Directory]::CreateDirectory($native)
            Set-FmBackendHerdrPrivateDirectoryMode $native
        } catch {
            if (-not (Test-FmBackendHerdrPresentationLockNamespace $native)) { return $null }
        }
    }
    if (-not (Test-FmBackendHerdrPresentationLockNamespace $native)) { return $null }
    return "$dir/order-$key.lock"
}

<#
.SYNOPSIS
Apply owner-only permissions to a directory where the platform has them.
.DESCRIPTION
The `mkdir -m 700` twin. Inert on Windows for the same reason chmod is, and
deliberately not replaced with an ACL grant there.
#>
function Set-FmBackendHerdrPrivateDirectoryMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin sets the mode unconditionally at mkdir time; a confirmation surface would diverge from the twin.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    try {
        [System.IO.Directory]::SetUnixFileMode($Path,
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::UserExecute)
    } catch {
        $null = $_
    }
}

# --- focus: the sole restoration authority ------------------------------------

<#
.SYNOPSIS
The exact active workspace and tab ids, as one TAB-separated record.
.DESCRIPTION
Twin of fm_backend_herdr_projection_focus_snapshot. Every presentation mutation
uses this read-only snapshot as its SOLE focus-restoration authority: labels,
workspace order and ambient client state are never focus authority.

Requires exactly one focused workspace with both ids present, and then
independently confirms through `tab list` that the workspace's own tab listing
agrees on exactly one focused tab with that id. The second read is what catches a
workspace whose active_tab_id has gone stale. Returns $null on any ambiguity, and
a $null snapshot is what makes every caller REFUSE rather than proceed.
#>
function Get-FmBackendHerdrProjectionFocusSnapshot {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $result.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut

    $focused = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        if (Test-FmBackendHerdrItemTrue -Item $item -Key 'focused') { $focused += , $item }
    }
    if ($focused.Count -ne 1) { return $null }
    $workspace = Get-FmBackendHerdrItemString -Item $focused[0] -Key 'workspace_id'
    $tab = Get-FmBackendHerdrItemString -Item $focused[0] -Key 'active_tab_id'
    if ([string]::IsNullOrEmpty($workspace) -or [string]::IsNullOrEmpty($tab)) { return $null }
    if ($workspace -ceq $tab) { return $null }

    $tabsResult = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $workspace)
    if (-not $tabsResult.Ok) { return $null }
    $tabsDoc = ConvertFrom-FmBackendHerdrJson $tabsResult.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))) { return $null }
    $focusedTabs = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))) {
        if (Test-FmBackendHerdrItemTrue -Item $item -Key 'focused') { $focusedTabs += , $item }
    }
    if ($focusedTabs.Count -ne 1) { return $null }
    if ((Get-FmBackendHerdrItemString -Item $focusedTabs[0] -Key 'tab_id') -cne $tab) { return $null }

    return "$workspace$($script:FmHerdrTab)$tab"
}

<#
.SYNOPSIS
Verify that one presentation mutation preserved the exact prior focus, restoring it if not.
.DESCRIPTION
Twin of fm_backend_herdr_projection_focus_restore, and the BACKSTOP behind every
focus-unsafe instant. On Herdr 0.7.5 an explicit pane.close that empties a
non-focused workspace moves focus to that workspace's neighbor (upstream
#1328/#1877), and a pane-death removal before a non-last focused workspace moves
focus to the focused workspace's right neighbor (upstream #1621/#1912); both
fixes are merged upstream but unreleased. A single tab.focus on the exact
response-independent pre-operation tab id restores both workspace and tab
atomically.

Returns $true when focus is already correct or was restored, $false after warning
on any ambiguity - and a caller that turns that $false into a refusal is doing
the right thing.
#>
function Restore-FmBackendHerdrProjectionFocus {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Before = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Operation = ''
    )

    if ([string]::IsNullOrEmpty($Before)) {
        Write-FmErr "warning: herdr presentation $Operation had no unambiguous pre-operation focus snapshot"
        return $false
    }
    $after = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ($null -eq $after) { $after = '' }
    if ($after -ceq $Before) { return $true }

    $split = $Before.IndexOf($script:FmHerdrTab)
    $workspace = if ($split -lt 0) { $Before } else { $Before.Substring(0, $split) }
    $tab = if ($split -lt 0) { $Before } else { $Before.Substring($split + 1) }

    $info = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'get', $tab)
    if (-not $info.Ok) {
        Write-FmErr "warning: herdr presentation $Operation changed focus and the exact prior tab could not be verified for restoration"
        return $false
    }
    $infoDoc = ConvertFrom-FmBackendHerdrJson $info.StdOut
    if ((Get-FmBackendHerdrJsonString $infoDoc @('result', 'tab', 'workspace_id')) -cne $workspace -or
        (Get-FmBackendHerdrJsonString $infoDoc @('result', 'tab', 'tab_id')) -cne $tab) {
        Write-FmErr "warning: herdr presentation $Operation changed focus and the exact prior tab response was ambiguous"
        return $false
    }
    if (-not (Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'focus', $tab)).Ok) {
        Write-FmErr "warning: herdr presentation $Operation changed focus and exact-tab restoration failed"
        return $false
    }
    $restored = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ($null -eq $restored) { $restored = '' }
    if ($restored -cne $Before) {
        Write-FmErr "warning: herdr presentation $Operation did not restore the exact prior workspace and tab"
        return $false
    }
    return $true
}

# --- presence classification --------------------------------------------------

<#
.SYNOPSIS
Classify one exact `pane get` response as dead|present|unknown.
.DESCRIPTION
Twin of fm_backend_herdr_pane_presence_state, and classified from the JSON BODY,
never from the process exit status: a business-logic "not found" is a normal
expected outcome here, not a call failure (real herdr exits 1 for it while the
canned-response fake exits 0, and parsing only the body keeps this correct against
either).

`dead` requires the structured error code pane_not_found. Anything else that is
not a clean round-trip of the same pane id is `unknown`, and `unknown` is what
makes every caller fail safe toward refusal.
#>
function Get-FmBackendHerdrPanePresenceState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'get', $PaneId)
    $doc = ConvertFrom-FmBackendHerdrJson (Get-FmBackendHerdrCombinedOutput $result)
    $code = Get-FmBackendHerdrJsonString $doc @('error', 'code')
    if (-not [string]::IsNullOrEmpty($code)) {
        if ($code -ceq 'pane_not_found') { return 'dead' }
        return 'unknown'
    }
    if ((Get-FmBackendHerdrJsonString $doc @('result', 'pane', 'pane_id')) -ceq $PaneId) { return 'present' }
    return 'unknown'
}

<#
.SYNOPSIS
Classify a workspace's presence as dead|present|unknown from one listing.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_presence_state. Used to CONFIRM that a
repositioned doomed workspace really was removed; an unconfirmed removal is what
triggers the move rollback rather than a silent reorder.
#>
function Get-FmBackendHerdrWorkspacePresenceState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = ''
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    $doc = ConvertFrom-FmBackendHerdrJson (Get-FmBackendHerdrCombinedOutput $result)
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) { return 'unknown' }
    $count = 0
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id') -ceq $WorkspaceId) { $count++ }
    }
    if ($count -eq 0) { return 'dead' }
    if ($count -eq 1) { return 'present' }
    return 'unknown'
}

<#
.SYNOPSIS
Classify a pane as dead|no-agent|live|unknown from two read-only calls.
.DESCRIPTION
Twin of fm_backend_herdr_pane_agent_state, purely from JSON bodies:

  dead     - `pane get` responds pane_not_found: the pane is gone (closed, or its
             process died and herdr reaped both the pane and its tab).
  no-agent - the pane structurally exists but `agent get` responds
             agent_not_found: nothing registered in it, which is exactly what a
             herdr session-layout restore produces.
  live     - `agent get` reports any registered agent_status. An IDLE or BLOCKED
             agent is still a genuine registered agent, not a restored husk, so it
             is never a close-and-replace candidate.
  unknown  - anything else, including a `pane get` success whose echoed pane id
             does not round-trip. The caller must fail safe toward refusal here.
#>
function Get-FmBackendHerdrPaneAgentState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $presence = Get-FmBackendHerdrPanePresenceState -Session $Session -PaneId $PaneId
    if ($presence -cne 'present') {
        if ($presence -ceq 'dead' -or $presence -ceq 'unknown') { return $presence }
        return 'unknown'
    }

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('agent', 'get', $PaneId)
    $doc = ConvertFrom-FmBackendHerdrJson (Get-FmBackendHerdrCombinedOutput $result)
    $code = Get-FmBackendHerdrJsonString $doc @('error', 'code')
    if (-not [string]::IsNullOrEmpty($code)) {
        if ($code -ceq 'agent_not_found') { return 'no-agent' }
        return 'unknown'
    }
    switch -CaseSensitive (Get-FmBackendHerdrJsonString $doc @('result', 'agent', 'agent_status')) {
        'working' { return 'live' }
        'idle' { return 'live' }
        'done' { return 'live' }
        'blocked' { return 'live' }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
True only for the two conservative husk states a pane read can positively confirm.
.DESCRIPTION
Twin of fm_backend_herdr_tab_is_husk. `live` and `unknown` both refuse, so an
inconclusive read never licenses closing anything - restored-layout recovery
depends on that fail-safe-toward-refusal direction.
#>
function Test-FmBackendHerdrTabIsHusk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    switch -CaseSensitive (Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $PaneId) {
        'dead' { return $true }
        'no-agent' { return $true }
        default { return $false }
    }
}

<#
.SYNOPSIS
The recovery-grade endpoint state for the session-start sweep.
.DESCRIPTION
Twin of fm_backend_herdr_agent_state, reusing the husk classifier rather than
creating a second Herdr state machine. THE DISTINCTIONS ARE RECOVERY-GRADE: a
structurally gone pane is `missing`, a confirmed agent-less pane is `dead`, a
registered agent is `alive`, and an unexpected or failed API read is
`unreadable`. Only `dead` and `missing` license recovery, so a transient read
failure that answered `dead` would license a duplicate spawn against a crew that
is still working - which is why every non-definitive outcome, including an
unparseable target, lands on `unreadable`.
#>
function Get-FmBackendHerdrAgentState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) { return 'unreadable' }
    switch -CaseSensitive (Get-FmBackendHerdrPaneAgentState -Session $parsed.Session -PaneId $parsed.Pane) {
        'dead' { return 'missing' }
        'no-agent' { return 'dead' }
        'live' { return 'alive' }
        default { return 'unreadable' }
    }
}

<#
.SYNOPSIS
Backward-compatible three-state view for callers that only need a yes/no verdict.
.DESCRIPTION
Twin of fm_backend_herdr_agent_alive. The detailed contract is owned by
Get-FmBackendHerdrAgentState.
#>
function Get-FmBackendHerdrAgentAlive {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    switch -CaseSensitive (Get-FmBackendHerdrAgentState $Target) {
        'alive' { return 'alive' }
        'dead' { return 'dead' }
        'missing' { return 'dead' }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
Gate durable-record removal on the exact recorded pane's structured presence.
.DESCRIPTION
Twin of fm_backend_herdr_endpoint_confirmed_gone. Read-only, so a refused,
skipped or failed close never erases a live task's endpoint identity. ONLY a
structured pane_not_found proves the endpoint gone; present and unknown both
refuse after every close path, and a missing or malformed target identity is
ambiguity that refuses the same way - never proof of a gone pane.
#>
function Test-FmBackendHerdrEndpointGone {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) { return $false }
    return ((Get-FmBackendHerdrPanePresenceState -Session $parsed.Session -PaneId $parsed.Pane) -ceq 'dead')
}

# --- workspace.move: the guarded raw-socket transport -------------------------
#
# Herdr 0.7.5 WORKSPACE-REMOVAL FOCUS RULES (verified against the installed
# binary, its v0.7.5 tag source, and the isolated named lab):
#  - An EXPLICIT close that empties a workspace (pane.close of its last pane, tab
#    close, or workspace close) routes through close_selected_workspace, which
#    assigns focus to the closing workspace's right neighbor (or the new last
#    workspace when it was last), ignoring the previously focused workspace
#    entirely (upstream discussion #1328, fixed by PR #1877, commit 165dca45).
#  - A PANE-DEATH removal (handle_pane_died) keeps the focused index stale, which
#    preserves the exact focused workspace whenever the dying workspace sat behind
#    it (or the focused workspace was last), and moves focus to the focused
#    workspace's right neighbor otherwise (upstream issue #1621, fixed by PR
#    #1912, commit a979916).
# Both fixes are merged upstream but in no release as of 2026-07-28. Firstmate
# therefore removes a doomed non-focused workspace by ending its verified lone
# idle shell (the pane-death path), repositioning it behind the focused workspace
# first when needed. Moving it to the END preserves every other workspace's
# relative order, so no presentation ordering change persists. A release carrying
# both fixes preserves focus on both paths, so this stays safe with no version
# gate.

<#
.SYNOPSIS
Can one guarded raw workspace.move request be made in this session?
.DESCRIPTION
Twin of fm_backend_herdr_workspace_move_capable, silent by design - each caller
owns its own warning wording. Returns 0 for capable, and otherwise the bash
twin's exact reason code:

  1 python3 missing   2 protocol unreadable   3 protocol too old
  4 schema unreadable 5 method or parameter schema unsupported

python3 is still required because bin/backends/herdr-workspace-move.py is still a
subprocess here (divergence 3 in the file header), so dropping the gate would
report capable on a host where the move cannot actually be sent.
#>
function Test-FmBackendHerdrWorkspaceMoveCapable {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    if (-not (Test-FmCommand 'python3')) { return 1 }

    $status = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('status', '--json')
    $protocol = Get-FmBackendHerdrJsonString (ConvertFrom-FmBackendHerdrJson $status.StdOut) @('client', 'protocol')
    $value = 0
    if ([string]::IsNullOrEmpty($protocol) -or
        -not [int]::TryParse($protocol, [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return 2
    }
    if ($value -lt $script:FmHerdrMinWorkspaceMoveProtocol) { return 3 }

    $schema = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('api', 'schema', '--json')
    if (-not $schema.Ok) { return 4 }
    $doc = ConvertFrom-FmBackendHerdrJson $schema.StdOut

    $hasMethod = $false
    foreach ($variant in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('schemas', 'request', 'oneOf'))) {
        if ((Get-FmBackendHerdrJsonString $variant @('properties', 'method', 'const')) -ceq 'workspace.move') {
            $hasMethod = $true
            break
        }
    }
    if (-not $hasMethod) { return 5 }

    $params = Get-FmBackendHerdrJsonValue -Document $doc -Path @('schemas', 'request', '$defs', 'WorkspaceMoveParams')
    $required = @(Get-FmBackendHerdrJsonArray -Document $params -Path @('required'))
    if ($required.Count -ne 2 -or $required[0] -cne 'workspace_id' -or $required[1] -cne 'insert_index') { return 5 }
    if ((Get-FmBackendHerdrJsonString $params @('properties', 'insert_index', 'type')) -cne 'integer') { return 5 }
    return 0
}

<#
.SYNOPSIS
Send one workspace.move through the guarded helper, returning its response.
.DESCRIPTION
The `"$mover" "$socket" "$ws" "$index"` twin. bin/backends/herdr-workspace-move.py
stays a SUBPROCESS rather than being absorbed - see divergence 3 in the file
header for the full argument, including why absorbing it would silently switch on
a presentation-ordering path that is inert in the bash world on Windows.

FM_BACKEND_HERDR_WORKSPACE_MOVER overrides the helper. A mover path ending in
`.py` is launched through the resolved python3 (then python) because .NET cannot
start a `.py` by its shebang the way bash does; any other mover path is executed
directly, which is what keeps a test seam's own executable working.

Returns @{ ExitCode; StdOut } with the bash twin's `2>/dev/null` already applied.
#>
function Invoke-FmBackendHerdrWorkspaceMove {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Socket,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InsertIndex
    )

    $mover = Get-FmEnv -Name 'FM_BACKEND_HERDR_WORKSPACE_MOVER'
    if ([string]::IsNullOrEmpty($mover)) {
        $mover = Join-Path $script:FmHerdrRoot 'bin' 'backends' 'herdr-workspace-move.py'
    }
    $moverNative = ConvertTo-FmNativePath $mover

    $file = $moverNative
    $argv = @($Socket, $WorkspaceId, $InsertIndex)
    if ($moverNative.EndsWith('.py', [System.StringComparison]::OrdinalIgnoreCase)) {
        $python = Get-Command 'python3' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $python) { $python = Get-Command 'python' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $python) { return @{ ExitCode = 127; StdOut = '' } }
        $file = $python.Source
        $argv = @($moverNative) + $argv
    }

    try {
        $result = Invoke-FmTool -FilePath $file -Arguments $argv
    } catch {
        return @{ ExitCode = 127; StdOut = '' }
    }
    return @{ ExitCode = $result.ExitCode; StdOut = $result.StdOut }
}

<#
.SYNOPSIS
Does a mover response prove the exact expected order and unchanged focus?
.DESCRIPTION
The shared verification both the reposition and its rollback apply. The response
must be a workspace_list whose workspace ids equal the expected sequence EXACTLY,
and whose single focused workspace is still the one that was focused before -
anything less is an unverifiable move, which is treated as a failure rather than
retried.
#>
function Test-FmBackendHerdrMoveResponse {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Response,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$ExpectedOrder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FocusedWorkspaceId
    )

    $doc = ConvertFrom-FmBackendHerdrJson $Response
    if ((Get-FmBackendHerdrJsonString $doc @('result', 'type')) -cne 'workspace_list') { return $false }
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) { return $false }

    $ids = @()
    $focused = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        $id = Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id'
        $ids += $id
        if (Test-FmBackendHerdrItemTrue -Item $item -Key 'focused') { $focused += $id }
    }
    $expected = @($ExpectedOrder)
    if ($ids.Count -ne $expected.Count) { return $false }
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if ($ids[$i] -cne $expected[$i]) { return $false }
    }
    if ($focused.Count -ne 1) { return $false }
    return ($focused[0] -ceq $FocusedWorkspaceId)
}

<#
.SYNOPSIS
Choose the focus-safe removal plan for one exact pane.
.DESCRIPTION
Twin of fm_backend_herdr_emptying_close_plan, whose multi-line stdout protocol
becomes this hashtable:

  Plan       'plain' - use the ordinary explicit close; the exact-tab restore
                       backstop masks 0.7.5's focus move.
             'death' - end the proved lone idle shell so Herdr removes the
                       emptied workspace through its focus-preserving pane-death
                       path.
  ShellPid   the proved shell pid, only when Plan is 'death'.
  MoveRecord non-empty whenever the repositioning mover was INVOKED - including
             an unverified invocation - so a later unconfirmed removal can restore
             the exact original order. Restoring an unmoved workspace to its own
             position is a verified no-op.

NEVER FAILS: every ambiguity plans 'plain'. The death plan requires the close to
empty the workspace (exactly one tab and one pane, both the target), the target
workspace to sit behind the focused one (repositioned to the end first when it
does not, with the move verified against the server-returned order and focus), and
the exact pane to hold one provably lone idle recognized shell.
#>
function Get-FmBackendHerdrEmptyingClosePlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FocusedWorkspaceId
    )

    $plain = @{ Plan = 'plain'; ShellPid = ''; MoveRecord = '' }
    if ([string]::IsNullOrEmpty($WorkspaceId) -or [string]::IsNullOrEmpty($TabId) -or
        [string]::IsNullOrEmpty($FocusedWorkspaceId)) {
        return $plain
    }

    $tabs = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $WorkspaceId)
    if (-not $tabs.Ok) { return $plain }
    $tabsDoc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))) { return $plain }
    $tabList = @(Get-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))
    if ($tabList.Count -ne 1) { return $plain }
    if ((Get-FmBackendHerdrItemString -Item $tabList[0] -Key 'tab_id') -cne $TabId) { return $plain }

    $panes = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $WorkspaceId)
    if (-not $panes.Ok) { return $plain }
    $panesDoc = ConvertFrom-FmBackendHerdrJson $panes.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))) { return $plain }
    $paneList = @(Get-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))
    if ($paneList.Count -ne 1) { return $plain }
    if ((Get-FmBackendHerdrItemString -Item $paneList[0] -Key 'pane_id') -cne $PaneId) { return $plain }

    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) { return $plain }
    $listDoc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'workspaces'))) { return $plain }
    $spaces = @(Get-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'workspaces'))
    if ($spaces.Count -le 1) { return $plain }

    $order = @()
    $targetIndex = @()
    $focusIndex = @()
    for ($i = 0; $i -lt $spaces.Count; $i++) {
        $id = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'workspace_id'
        $order += $id
        if ($id -ceq $WorkspaceId) { $targetIndex += $i }
        if ($id -ceq $FocusedWorkspaceId) { $focusIndex += $i }
    }
    if ($targetIndex.Count -ne 1 -or $focusIndex.Count -ne 1) { return $plain }
    if ($targetIndex[0] -eq $focusIndex[0]) { return $plain }

    $moveRecord = ''
    if ($targetIndex[0] -lt $focusIndex[0] -and $focusIndex[0] -lt ($spaces.Count - 1)) {
        # The doomed workspace sits BEFORE the focused one, where the pane-death
        # path would land focus on the focused workspace's right neighbor.
        # Reposition it behind everything first: insert_index equal to the list
        # length is the verified move-to-last form, and removing the moved
        # workspace afterward leaves every other relative order untouched.
        if ((Test-FmBackendHerdrWorkspaceMoveCapable $Session) -ne 0) {
            Write-FmErr 'warning: herdr presentation cleanup could not verify workspace.move support; closing without the focus-safe removal path'
            return $plain
        }
        $socket = Get-FmBackendHerdrPresentationSessionSocketPath $Session
        if ([string]::IsNullOrEmpty($socket)) {
            Write-FmErr 'warning: herdr presentation cleanup found an ambiguous named session socket; closing without the focus-safe removal path'
            return $plain
        }
        $beforeOrder = ConvertTo-Json -InputObject @($order) -Depth 5 -Compress
        $move = Invoke-FmBackendHerdrWorkspaceMove -Socket $socket -WorkspaceId $WorkspaceId `
            -InsertIndex ([string]$spaces.Count)
        # Every mover invocation is recorded, even an unverified one.
        $moveRecord = "moved$($script:FmHerdrTab)$WorkspaceId$($script:FmHerdrTab)$($targetIndex[0])$($script:FmHerdrTab)$socket$($script:FmHerdrTab)$FocusedWorkspaceId$($script:FmHerdrTab)$beforeOrder"

        $expected = @($order | Where-Object { $_ -cne $WorkspaceId }) + @($WorkspaceId)
        if ($move.ExitCode -ne 0 -or
            -not (Test-FmBackendHerdrMoveResponse -Response $move.StdOut -ExpectedOrder $expected `
                    -FocusedWorkspaceId $FocusedWorkspaceId)) {
            Write-FmErr 'warning: herdr presentation cleanup could not move the doomed workspace behind the focused one; closing without the focus-safe removal path'
            return @{ Plan = 'plain'; ShellPid = ''; MoveRecord = $moveRecord }
        }
    }

    $shellPid = Get-FmBackendHerdrPaneIdleShellPid -Session $Session -PaneId $PaneId
    if ([string]::IsNullOrEmpty($shellPid)) {
        return @{ Plan = 'plain'; ShellPid = ''; MoveRecord = $moveRecord }
    }
    return @{ Plan = 'death'; ShellPid = $shellPid; MoveRecord = $moveRecord }
}

<#
.SYNOPSIS
Restore the exact pre-move workspace order after an unconfirmed removal.
.DESCRIPTION
Twin of fm_backend_herdr_emptying_move_rollback, run under the caller's still-held
session lock. An empty record is a no-op (no move was attempted). The rollback is
verified against the mover's returned order and focus and WARNS on any failure, so
a lasting reorder is never silent.

The record is split preserving empty fields and the field count is asserted,
rather than read through the collapsing `IFS=$'\t' read` the bash twin uses. A
record with an empty field is malformed and refused either way; splitting without
collapsing means it is refused as malformed rather than silently field-shifted.
#>
function Restore-FmBackendHerdrEmptyingMove {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$MoveRecord = '')

    if ([string]::IsNullOrEmpty($MoveRecord)) { return $true }
    $fields = @($MoveRecord.Split($script:FmHerdrTab))
    $malformed = 'warning: herdr presentation cleanup has a malformed move record after a failed removal; the workspace order may remain changed'
    if ($fields.Count -ne 6) { Write-FmErr $malformed; return $false }

    $marker = $fields[0]
    $workspaceId = $fields[1]
    $index = $fields[2]
    $socket = $fields[3]
    $focused = $fields[4]
    $orderJson = $fields[5]
    if ($marker -cne 'moved' -or [string]::IsNullOrEmpty($workspaceId) -or
        [string]::IsNullOrEmpty($socket) -or [string]::IsNullOrEmpty($orderJson)) {
        Write-FmErr $malformed
        return $false
    }
    if ([string]::IsNullOrEmpty($index) -or $index -notmatch '^[0-9]+$') {
        Write-FmErr $malformed
        return $false
    }

    $expected = @()
    try {
        $expected = @(ConvertFrom-Json -InputObject $orderJson -AsHashtable -Depth 5)
    } catch {
        Write-FmErr $malformed
        return $false
    }

    $move = Invoke-FmBackendHerdrWorkspaceMove -Socket $socket -WorkspaceId $workspaceId -InsertIndex $index
    if ($move.ExitCode -ne 0 -or
        -not (Test-FmBackendHerdrMoveResponse -Response $move.StdOut -ExpectedOrder ([string[]]$expected) `
                -FocusedWorkspaceId $focused)) {
        Write-FmErr 'warning: herdr presentation cleanup could not restore the original workspace order after a failed removal'
        return $false
    }
    return $true
}

# --- the idle-shell proof and the two close paths -----------------------------

<#
.SYNOPSIS
Does this pid currently resolve to a bare recognized shell?
.DESCRIPTION
Twin of fm_backend_herdr_pid_is_bare_shell. BSD ps reports comm as argv0, so a
login shell arrives as "-zsh"; the login dash is stripped exactly like the
idle-shell proof's argv0 normalization.

The accepted list here EXCLUDES powershell/pwsh, and that asymmetry with
Get-FmBackendHerdrPaneIdleShellSample is deliberate and matches the bash twin: the
sample must recognize the shell a Herdr Windows pane genuinely runs, while this
gates a SIGNAL and must not widen what may be signalled.
#>
function Test-FmBackendHerdrBareShellPid {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$PsBin,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$ProcessId
    )

    $ps = Get-Command $PsBin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ps) { return $false }
    $result = Invoke-FmTool -FilePath $ps.Source -Arguments @('-p', $ProcessId, '-o', 'comm=')
    if (-not $result.Ok) { return $false }
    $comm = ($result.StdOut -replace '[\t\n\v\f\r ]', '')
    if ($comm.StartsWith('-')) { $comm = $comm.Substring(1) }
    $slash = $comm.LastIndexOf('/')
    if ($slash -ge 0) { $comm = $comm.Substring($slash + 1) }
    return ([Array]::IndexOf($script:FmHerdrKillableShells, $comm) -ge 0)
}

<#
.SYNOPSIS
One strict instantaneous observation of a pane's lone idle shell.
.DESCRIPTION
Twin of fm_backend_herdr_pane_idle_shell_sample. Get-FmBackendHerdrPaneIdleShellPid
owns the proof contract and the settle retry; this is a single sample.

The proof requires ALL of: the pane process-info response agrees on the pane id;
the shell pid is both the foreground process group and the sole foreground
process; the foreground process name and argv0 resolve to the same recognized
shell; the operating-system process table shows exactly that one shell row with no
child process; and the shell sits in a sleeping or idle state.

WINDOWS NORMALIZATION, verified live: argv0 arrives as a full BACKSLASH path
("C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"), which a
forward-slash basename strip never touches, so that separator is peeled too, and
both sides are lowercased with any .exe suffix removed so "PowerShell.EXE" and
"powershell" agree. powershell/pwsh are ACCEPTED shells because a Herdr Windows
pane genuinely runs one - excluding them would make this proof unsatisfiable and
every gentle close spin its full retry budget on Windows (verified live: the
session-cleanup e2e sat in this loop for minutes).

The OS-table cross-check is SKIPPED when `ps` cannot answer it, exactly as the
bash twin skips it: Cygwin ps (Git Bash) supports neither -axo nor -o stat=, and
the pane shell is a NATIVE Windows process invisible to it anyway. Reading the
native process table instead would make this stricter than the bash twin on the
same host - see "WHAT IS FAITHFUL EVEN THOUGH POWERSHELL COULD DO BETTER".
#>
function Get-FmBackendHerdrPaneIdleShellSample {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'process-info', '--pane', $PaneId)
    if (-not $result.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    if ((Get-FmBackendHerdrJsonString $doc @('result', 'type')) -cne 'pane_process_info') { return $null }
    if ((Get-FmBackendHerdrJsonString $doc @('result', 'process_info', 'pane_id')) -cne $PaneId) { return $null }

    $shellPid = Get-FmBackendHerdrJsonNumber -Document $doc -Path @('result', 'process_info', 'shell_pid') -Minimum 2
    if ($null -eq $shellPid) { return $null }
    $pgid = Get-FmBackendHerdrJsonNumber -Document $doc -Path @('result', 'process_info', 'foreground_process_group_id') -Minimum 2
    if ($null -eq $pgid) { return $null }
    if ($pgid -ne $shellPid) { return $null }

    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'process_info', 'foreground_processes'))) { return $null }
    $foreground = @(Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'process_info', 'foreground_processes'))
    if ($foreground.Count -ne 1) { return $null }

    $processPid = Get-FmBackendHerdrJsonNumber -Document $foreground[0] -Path @('pid')
    if ($null -eq $processPid -or $processPid -ne $shellPid) { return $null }
    $name = Get-FmBackendHerdrItemString -Item $foreground[0] -Key 'name'
    if ([string]::IsNullOrEmpty($name)) { return $null }
    $argv0 = Get-FmBackendHerdrItemString -Item $foreground[0] -Key 'argv0'
    if ([string]::IsNullOrEmpty($argv0)) {
        $argv = @(Get-FmBackendHerdrJsonArray -Document $foreground[0] -Path @('argv'))
        if ($argv.Count -gt 0 -and $argv[0] -is [string]) { $argv0 = [string]$argv[0] }
    }
    if ([string]::IsNullOrEmpty($argv0)) { return $null }

    $shellName = Get-FmBackendHerdrShellLeaf $name
    if ($argv0.StartsWith('-')) { $argv0 = $argv0.Substring(1) }
    $argv0Leaf = Get-FmBackendHerdrShellLeaf $argv0
    if ($argv0Leaf -cne $shellName) { return $null }
    if ([Array]::IndexOf($script:FmHerdrPaneShells, $shellName) -lt 0) { return $null }

    $psBin = Get-FmEnv -Name 'FM_HERDR_PS_BIN' -Default 'ps'
    $ps = Get-Command $psBin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ps) { return $null }

    $rows = Invoke-FmTool -FilePath $ps.Source -Arguments @('-axo', 'pid=,ppid=')
    if ($rows.Ok) {
        $found = 0
        $child = 0
        foreach ($line in $rows.StdOut.Split("`n")) {
            $columns = @($line.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries))
            if ($columns.Count -lt 1) { continue }
            if ($columns[0] -ceq ([string]$shellPid)) { $found++ }
            if ($columns.Count -ge 2 -and $columns[1] -ceq ([string]$shellPid)) { $child++ }
        }
        if ($found -ne 1 -or $child -ne 0) { return $null }
        $stat = Invoke-FmTool -FilePath $ps.Source -Arguments @('-p', [string]$shellPid, '-o', 'stat=')
        if (-not $stat.Ok) { return $null }
        $state = ($stat.StdOut -replace '[\t\n\v\f\r ]', '')
        if (-not ($state.StartsWith('S') -or $state.StartsWith('I'))) { return $null }
    }
    return [string]$shellPid
}

<#
.SYNOPSIS
The basename of a shell path, peeling BOTH separators, lowercased, .exe removed.
#>
function Get-FmBackendHerdrShellLeaf {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    if ([string]::IsNullOrEmpty($Name)) { return '' }
    $leaf = $Name
    $slash = $leaf.LastIndexOf('/')
    if ($slash -ge 0) { $leaf = $leaf.Substring($slash + 1) }
    $back = $leaf.LastIndexOf('\')
    if ($back -ge 0) { $leaf = $leaf.Substring($back + 1) }
    $leaf = $leaf.ToLowerInvariant()
    if ($leaf.EndsWith('.exe')) { $leaf = $leaf.Substring(0, $leaf.Length - 4) }
    return $leaf
}

<#
.SYNOPSIS
A JSON number field, floored, or $null when it is not a number above the minimum.
.DESCRIPTION
The `jq -er '... | select(type == "number" and . > N) | floor'` twin.
#>
function Get-FmBackendHerdrJsonNumber {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$Path,
        [Parameter(Position = 2)][AllowNull()][object]$Minimum = $null
    )

    $value = Get-FmBackendHerdrJsonValue -Document $Document -Path $Path
    if ($null -eq $value) { return $null }
    if ($value -is [bool] -or $value -is [string]) { return $null }
    $number = 0.0
    try {
        $number = [double]$value
    } catch {
        return $null
    }
    if ($null -ne $Minimum -and $number -le [double]$Minimum) { return $null }
    return [long][Math]::Floor($number)
}

<#
.SYNOPSIS
The pane's shell pid, only when the exact pane provably holds one lone idle shell.
.DESCRIPTION
Twin of fm_backend_herdr_pane_idle_shell_pid, and the SINGLE OWNER of the
idle-shell proof - the session-start projection cleanup and every pane-death close
path both rely on it.

An idle interactive shell transiently hosts short-lived prompt helpers (verified
on the real 0.7.5 lab: a workspace.move relayout makes zsh redraw its prompt,
spawning starship as a second foreground process for a few samples), so the proof
retries strict single samples for a bounded settle window and succeeds on the
first fully clean one; a genuinely busy pane fails every sample and still refuses.
#>
function Get-FmBackendHerdrPaneIdleShellPid {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )

    $maxAttempts = Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS' 10
    $attempt = 0
    while ($true) {
        $sample = Get-FmBackendHerdrPaneIdleShellSample -Session $Session -PaneId $PaneId
        if (-not [string]::IsNullOrEmpty($sample)) { return $sample }
        $attempt++
        if ($attempt -ge $maxAttempts) { return $null }
        Start-Sleep -Milliseconds 100
    }
}

<#
.SYNOPSIS
End the pane's proved lone idle shell so Herdr removes the emptied workspace.
.DESCRIPTION
Twin of fm_backend_herdr_death_close_pane. Herdr's pane-death path is the
focus-preserving one; this drives it and then CONFIRMS the pane is gone.

THE SIGNALS ARE PID-EXACT. SIGHUP relies on the bare-shell proof taken
immediately before it, and the SIGKILL escalation RE-READS the pane's process
information and refuses unless the same pid is still the pane's strict bare idle
shell - so an exited and reused pid is never signalled.

Returns $true only when the pane is confirmed gone.
#>
function Close-FmBackendHerdrPaneByDeath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ShellPid
    )

    if ([string]::IsNullOrEmpty($ShellPid) -or $ShellPid -notmatch '^[0-9]+$') { return $false }
    $psBin = Get-FmEnv -Name 'FM_HERDR_PS_BIN' -Default 'ps'
    if (-not (Get-Command $psBin -CommandType Application -ErrorAction SilentlyContinue)) { return $false }

    $maxAttempts = Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_DEATH_CLOSE_POLLS' 40
    if (-not (Test-FmBackendHerdrBareShellPid -PsBin $psBin -ProcessId $ShellPid)) { return $false }

    Send-FmBackendHerdrSignal -Signal 'HUP' -ProcessId $ShellPid
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        if ((Get-FmBackendHerdrPanePresenceState -Session $Session -PaneId $PaneId) -ceq 'dead') { return $true }
        Start-Sleep -Milliseconds 50
    }

    # SIGKILL escalation revalidates exact pane OWNERSHIP, not just the pid: a
    # fresh strict pane sample must still name the SAME shell pid.
    $resampled = Get-FmBackendHerdrPaneIdleShellSample -Session $Session -PaneId $PaneId
    if ([string]::IsNullOrEmpty($resampled) -or $resampled -cne $ShellPid) { return $false }
    if (-not (Test-FmBackendHerdrBareShellPid -PsBin $psBin -ProcessId $ShellPid)) { return $false }

    Send-FmBackendHerdrSignal -Signal 'KILL' -ProcessId $ShellPid
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        if ((Get-FmBackendHerdrPanePresenceState -Session $Session -PaneId $PaneId) -ceq 'dead') { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

<#
.SYNOPSIS
Send one POSIX signal through the external `kill`, best-effort.
.DESCRIPTION
The `kill -HUP "$pid" 2>/dev/null || true` twin. HUP and TERM do not exist on
Windows (docs/powershell-port.md, "Signals"), and this path is unreachable there
anyway because Test-FmBackendHerdrBareShellPid's `ps -o comm=` gate cannot be
satisfied by Cygwin ps - so the divergence is documented rather than faked with a
native Stop-Process, which would kill a process the bash twin would have left
alone.
#>
function Send-FmBackendHerdrSignal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin signals unconditionally behind its own pid-exact proof; a confirmation surface would diverge from the twin and could strand a doomed workspace.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Mandatory)][string]$ProcessId
    )

    $kill = Get-Command 'kill' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $kill) { return }
    try {
        [void](Invoke-FmTool -FilePath $kill.Source -Arguments @("-$Signal", $ProcessId))
    } catch {
        $null = $_
    }
}

<#
.SYNOPSIS
Issue one explicit close and succeed only when the exact pane is proved gone.
.DESCRIPTION
Twin of fm_backend_herdr_explicit_close_pane_confirmed. Confirmation is POLLED,
not read once: an accepted `pane close` tears the pane down asynchronously on
Windows (ConPTY unwind - verified live: the close returns ok while an immediate
presence read still says present), and a single instant read would report a
successful close as failed. The first read still short-circuits on already-dead
panes everywhere else.

Under the scripted-CLI test seam the poll collapses to the original single read:
every extra read would consume a response fixture scripted for a later call.
#>
function Close-FmBackendHerdrPaneExplicit {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )

    if (-not (Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'close', $PaneId)).Ok) { return $false }

    $maxAttempts = Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_DEATH_CLOSE_POLLS' 40
    if (Test-FmBackendHerdrScriptedCli) { $maxAttempts = 1 }
    $attempt = 0
    while ($true) {
        if ((Get-FmBackendHerdrPanePresenceState -Session $Session -PaneId $PaneId) -ceq 'dead') { return $true }
        $attempt++
        if ($attempt -ge $maxAttempts) { return $false }
        Start-Sleep -Milliseconds 50
    }
}

<#
.SYNOPSIS
Close one exact response-derived projection pane without moving the captain's focus.
.DESCRIPTION
Twin of fm_backend_herdr_projection_close_pane_focus_preserving, whose 0/1/2 exit
status and FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE global become
@{ Code; AgentState }:

  Code 0  the exact pane was closed and confirmed gone.
  Code 1  refused, or the close could not be confirmed.
  Code 2  the close outcome stands but FOCUS could not be restored - a distinct
          verdict because the reclaim path escalates on it rather than retrying.

If the target belongs to the ACTIVE tab, exact tab preservation is impossible, so
this REFUSES rather than changing focus. When the close would empty the target
workspace, the plan comes from Get-FmBackendHerdrEmptyingClosePlan; any ambiguity
there falls back to the plain explicit close, which the exact-tab restore backstop
masks exactly as before this hardening.
#>
function Close-FmBackendHerdrProjectionPane {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$RequiredAgentState = ''
    )

    if ([string]::IsNullOrEmpty($PaneId)) { return @{ Code = 0; AgentState = '' } }

    $before = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ([string]::IsNullOrEmpty($before)) {
        Write-FmErr 'warning: herdr presentation cleanup could not capture exact active workspace and tab; refusing focus-unsafe pane close'
        return @{ Code = 1; AgentState = '' }
    }
    $split = $before.IndexOf($script:FmHerdrTab)
    $focusedWorkspace = $before.Substring(0, $split)
    $activeTab = $before.Substring($split + 1)

    $info = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'get', $PaneId)
    if (-not $info.Ok) {
        Write-FmErr 'warning: herdr presentation cleanup could not verify the exact pane; refusing focus-unsafe pane close'
        return @{ Code = 1; AgentState = '' }
    }
    $infoDoc = ConvertFrom-FmBackendHerdrJson $info.StdOut
    $targetPane = Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'pane_id')
    $targetTab = Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'tab_id')
    $targetWorkspace = Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'workspace_id')
    if ($targetPane -cne $PaneId -or [string]::IsNullOrEmpty($targetTab)) {
        Write-FmErr 'warning: herdr presentation cleanup received an ambiguous exact-pane response; refusing focus-unsafe pane close'
        return @{ Code = 1; AgentState = '' }
    }
    if ($targetTab -ceq $activeTab) {
        Write-FmErr "warning: herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus"
        return @{ Code = 1; AgentState = '' }
    }

    $agentState = ''
    if (-not [string]::IsNullOrEmpty($RequiredAgentState)) {
        $agentState = Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $PaneId
        if ($agentState -cne $RequiredAgentState) { return @{ Code = 1; AgentState = $agentState } }
    }

    $plan = @{ Plan = 'plain'; ShellPid = ''; MoveRecord = '' }
    if (-not [string]::IsNullOrEmpty($targetWorkspace)) {
        $plan = Get-FmBackendHerdrEmptyingClosePlan -Session $Session -PaneId $PaneId `
            -WorkspaceId $targetWorkspace -TabId $targetTab -FocusedWorkspaceId $focusedWorkspace
    }

    $closed = $false
    if ($plan.Plan -ceq 'death') {
        $closed = (Close-FmBackendHerdrPaneByDeath -Session $Session -PaneId $PaneId -ShellPid $plan.ShellPid)
        if (-not $closed) { $closed = (Close-FmBackendHerdrPaneExplicit -Session $Session -PaneId $PaneId) }
    } else {
        $closed = (Close-FmBackendHerdrPaneExplicit -Session $Session -PaneId $PaneId)
    }

    if ($closed -and -not [string]::IsNullOrEmpty($plan.MoveRecord)) {
        if ((Get-FmBackendHerdrWorkspacePresenceState -Session $Session -WorkspaceId $targetWorkspace) -cne 'dead') {
            Write-FmErr 'warning: herdr presentation cleanup did not confirm removal of the repositioned workspace'
            $closed = $false
        }
    }
    if (-not $closed) {
        [void](Restore-FmBackendHerdrEmptyingMove $plan.MoveRecord)
    }
    if (-not (Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $before -Operation 'pane close')) {
        return @{ Code = 2; AgentState = $agentState }
    }
    if ($closed) { return @{ Code = 0; AgentState = $agentState } }
    return @{ Code = 1; AgentState = $agentState }
}

# --- workspaces: finding, and the launcher identity ---------------------------

<#
.SYNOPSIS
EVERY workspace id in a session whose label equals this HOME's own label.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_find_all, and the SINGLE OWNER of the
home-label workspace query. Herdr enforces NO workspace label uniqueness at all,
so this can legitimately return MORE THAN ONE id: a captain-owned workspace can
collide by label, a cwd-basename-derived label can coincide, and concurrent first
spawns can mint two same-labeled home workspaces. Callers decide what a duplicate
means for them - Initialize-FmBackendHerdrWorkspace refuses to guess which one is
the caller's, while the read-only recovery path keeps its historical first-match
behavior.

Returned in herdr's own list order (normally creation order, oldest first).
Never creates anything.
#>
function Get-FmBackendHerdrWorkspaceMatch {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $label = Get-FmBackendHerdrWorkspaceLabel
    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $result.Ok) { return @() }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    $ids = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'label') -ceq $label) {
            $ids += (Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id')
        }
    }
    return [string[]]$ids
}

<#
.SYNOPSIS
This HOME's own workspace id, or '' - read-only, never creates.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_find. Safe for recovery and list paths, which
address panes they already recorded and only need a container to scan; it keeps
the historical FIRST-match behavior on a label collision. NOT the spawn-time
resolver: placing a new worker by first label match is exactly the defect
Initialize-FmBackendHerdrWorkspace refuses.
#>
function Get-FmBackendHerdrWorkspace {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $matched = @(Get-FmBackendHerdrWorkspaceMatch $Session)
    if ($matched.Count -eq 0) { return '' }
    return $matched[0]
}

<#
.SYNOPSIS
The EXACT herdr workspace the process making this spawn is itself running in.
.DESCRIPTION
Twin of fm_backend_herdr_launcher_identity, whose three shell globals become this
hashtable's PaneId/TabId/WorkspaceId.

Herdr 0.7.5 injects HERDR_ENV, HERDR_PANE_ID, HERDR_SESSION, HERDR_SOCKET_PATH,
HERDR_TAB_ID and HERDR_WORKSPACE_ID into every process it manages a pane for, and
an agent's own tool calls inherit them. Workspace LABELS are mutable and herdr
enforces no uniqueness on them, so a label search cannot tell one `firstmate`
workspace from another, and herdr's globally focused workspace is whatever the
captain happens to be looking at, not the launcher's.

THE INJECTED HERDR_TAB_ID/HERDR_WORKSPACE_ID ARE DELIBERATELY NOT READ AS THE
ANSWER. They are a snapshot taken when the pane's process started, and herdr can
move a pane between tabs and workspaces afterwards without rewriting a running
process's environment. Only a LIVE read is the current parent, which is what
placement has to bind to.

Code:
  0 - one exact, self-consistent launcher pane/tab/workspace in this session.
  2 - this process is NOT running in a herdr pane (no HERDR_PANE_ID at all), so
      there is no launcher workspace to inherit and the caller falls back to its
      per-home container. HERDR_ENV=1 alone is only a backend SELECTION marker,
      never a parent binding - herdr always injects the pane id alongside it.
  1 - a launcher pane IS claimed but its binding is missing, stale, contradictory,
      or belongs to another herdr session. The caller must REFUSE before creating
      or publishing any worker endpoint rather than degrading to a label search.
#>
function Get-FmBackendHerdrLauncherIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $none = @{ Code = 2; PaneId = ''; TabId = ''; WorkspaceId = '' }
    $refuse = @{ Code = 1; PaneId = ''; TabId = ''; WorkspaceId = '' }

    $pane = Get-FmEnv -Name 'HERDR_PANE_ID'
    if ([string]::IsNullOrEmpty($pane)) { return $none }

    # Same-session proof, BEFORE the pane id is trusted at all: herdr pane ids
    # ("w2:p1") restart at the same low numbers in every session, so a pane id
    # borrowed from another session can silently resolve to a real but unrelated
    # workspace here.
    $claimedSession = Get-FmBackendHerdrSession
    if ($claimedSession -cne $Session) {
        Write-FmErr "error: herdr launcher pane '$pane' reports session '$claimedSession' but this spawn targets session '$Session'; refusing to place a worker from a cross-session parent identity"
        return $refuse
    }
    $claimedSocket = Get-FmEnv -Name 'HERDR_SOCKET_PATH'
    if ([string]::IsNullOrEmpty($claimedSocket)) {
        Write-FmErr "error: herdr launcher pane '$pane' has no injected socket identity; refusing to place a worker from an unverifiable parent identity"
        return $refuse
    }
    $claimedSocket = Get-FmBackendHerdrCanonicalSocketPath $claimedSocket
    if ([string]::IsNullOrEmpty($claimedSocket)) {
        Write-FmErr "error: herdr launcher pane '$pane' reports an unusable socket path; refusing to place a worker from an unverifiable parent identity"
        return $refuse
    }
    $sessionSocket = Get-FmBackendHerdrPresentationSessionSocketPath $Session
    if ([string]::IsNullOrEmpty($sessionSocket)) {
        Write-FmErr "error: herdr session '$Session' has no unambiguous socket to match against the launcher pane's own; refusing to place a worker from an unverifiable parent identity"
        return $refuse
    }
    if ($claimedSocket -cne $sessionSocket) {
        Write-FmErr "error: herdr launcher pane '$pane' belongs to the server at '$claimedSocket', not session '$Session' at '$sessionSocket'; refusing to place a worker from a cross-session parent identity"
        return $refuse
    }

    $paneOut = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'get', $pane)
    if (-not $paneOut.Ok) {
        Write-FmErr "error: herdr launcher pane '$pane' could not be read in session '$Session'; refusing to place a worker without its exact parent workspace"
        return $refuse
    }
    $paneDoc = ConvertFrom-FmBackendHerdrJson $paneOut.StdOut
    $tab = ''
    $workspace = ''
    if ((Get-FmBackendHerdrJsonString $paneDoc @('result', 'pane', 'pane_id')) -ceq $pane) {
        $tab = Get-FmBackendHerdrJsonString $paneDoc @('result', 'pane', 'tab_id')
        $workspace = Get-FmBackendHerdrJsonString $paneDoc @('result', 'pane', 'workspace_id')
    }
    if ([string]::IsNullOrEmpty($tab) -or [string]::IsNullOrEmpty($workspace)) {
        Write-FmErr "error: herdr launcher pane '$pane' returned an ambiguous tab or workspace identity in session '$Session'; refusing to place a worker without its exact parent workspace"
        return $refuse
    }

    # INDEPENDENT SECOND READ: the tab must agree that it lives in the same
    # workspace the pane just claimed. A restored-but-stale pane record that
    # disagrees with its own tab is exactly the contradictory binding this must
    # refuse rather than resolve.
    $tabOut = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'get', $tab)
    if (-not $tabOut.Ok) {
        Write-FmErr "error: herdr launcher tab '$tab' could not be read in session '$Session'; refusing to place a worker without its exact parent workspace"
        return $refuse
    }
    $tabDoc = ConvertFrom-FmBackendHerdrJson $tabOut.StdOut
    if ((Get-FmBackendHerdrJsonString $tabDoc @('result', 'tab', 'tab_id')) -cne $tab -or
        (Get-FmBackendHerdrJsonString $tabDoc @('result', 'tab', 'workspace_id')) -cne $workspace) {
        Write-FmErr "error: herdr launcher pane '$pane' and tab '$tab' disagree about their workspace in session '$Session'; refusing to place a worker from a contradictory parent identity"
        return $refuse
    }

    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) {
        Write-FmErr "error: could not list herdr workspaces in session '$Session' to confirm the launcher's own workspace '$workspace'; refusing to place a worker without its exact parent workspace"
        return $refuse
    }
    $listDoc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    $seen = 0
    if (Test-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'workspaces')) {
        foreach ($item in (Get-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'workspaces'))) {
            if ((Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id') -ceq $workspace) { $seen++ }
        }
    }
    if ($seen -ne 1) {
        Write-FmErr "error: herdr launcher workspace '$workspace' is missing or duplicated in session '$Session'; refusing to place a worker from a stale parent identity"
        return $refuse
    }

    return @{ Code = 0; PaneId = $pane; TabId = $tab; WorkspaceId = $workspace }
}

<#
.SYNOPSIS
Close EXACTLY the seeded default tab this same container-ensure call created.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_prune_seeded_default_tab.

LIVE-FIRE INCIDENT FIX (2026-07-02). The prior implementation re-derived
"prunable" at create-task time from a pure LABEL heuristic - exactly one tab,
labeled "1" - run against whatever workspace the label search had just resolved.
Herdr enforces no label uniqueness and derives an unlabeled workspace's DISPLAYED
label from its pane cwd's basename, so a captain launching herdr directly inside a
directory named "firstmate" produced a workspace that looked byte-identical, by
label alone, to firstmate's own auto-created container - one tab, label "1". The
label search adopted that pre-existing, captain-owned, LIVE workspace, the
heuristic matched too, and the very next spawn closed the captain's own live pane
27ms after creating its task tab.

THE FIX IS STRUCTURAL, NOT ANOTHER HEURISTIC: only a workspace this same
Initialize-FmBackendHerdrWorkspace call just CREATED carries a non-empty
SeededTabId at all; an ADOPTED workspace's SeededTabId is always empty, so
New-FmBackendHerdrTask never calls this for one, regardless of how its tabs
happen to be labeled. Nothing in this function may ever re-derive its target.

Defense in depth ON TOP of that gate (not the primary mechanism): re-verify the
tab is still present, still carries label "1" (a human could have renamed or
repurposed it), and refuse to close it if its pane hosts an actively WORKING agent.

Also verified against the real binary: closing a workspace's LAST remaining tab
deletes the whole workspace. So this must never run while the seeded tab is still
the ONLY tab - callers invoke it once a real task tab exists alongside it - and the
tab count is independently re-checked here as a second layer.

Best-effort: a failure here never fails the caller, mirroring the kill contract.
#>
function Remove-FmBackendHerdrSeededDefaultTab {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin prunes unconditionally behind its own structural gate; a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SeededTabId,
        [Parameter()][AllowEmptyString()][string]$CloseMode = 'direct'
    )

    if ([string]::IsNullOrEmpty($SeededTabId)) { return $true }
    $tabs = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $WorkspaceId)
    if (-not $tabs.Ok) { return $true }
    $doc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut
    $tabList = @(Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'tabs'))
    if ($tabList.Count -le 1) { return $true }

    $currentLabel = ''
    foreach ($item in $tabList) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'tab_id') -ceq $SeededTabId) {
            $currentLabel = Get-FmBackendHerdrItemString -Item $item -Key 'label'
        }
    }
    if ($currentLabel -cne '1') { return $true }

    $paneId = Get-FmBackendHerdrPaneForTab -Session $Session -WorkspaceId $WorkspaceId -TabId $SeededTabId
    if ([string]::IsNullOrEmpty($paneId)) { return $true }

    $agent = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('agent', 'get', $paneId)
    $agentDoc = ConvertFrom-FmBackendHerdrJson $agent.StdOut
    if ((Get-FmBackendHerdrJsonString $agentDoc @('result', 'agent', 'agent_status')) -ceq 'working') { return $true }

    if ($CloseMode -ceq 'focus-preserving') {
        return ((Close-FmBackendHerdrProjectionPane -Session $Session -PaneId $paneId).Code -eq 0)
    }
    [void](Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'close', $paneId))
    return $true
}

<#
.SYNOPSIS
Resolve the workspace this spawn's task tab belongs in, creating it if needed.
.DESCRIPTION
Twin of fm_backend_herdr_workspace_ensure, whose two shell globals become
WorkspaceId and SeededTabId. The bash twin's "call as a plain statement, never
through command substitution" warning has no analogue here - that hazard exists
only because a subshell would swallow the globals.

  Code 0  resolved. WorkspaceId is the container.
  Code 3  a REFUSAL whose exact reason is already on stderr.
  Code 1  a failed or unparseable herdr call.

SeededTabId is non-empty ONLY when THIS call just CREATED the workspace: the
tab_id of the auto-created default tab herdr seeded it with, read straight from
the `workspace create` response's `.result.tab.tab_id` (verified empirically - no
follow-up tab-list call needed). It is EMPTY whenever this call instead ADOPTED a
pre-existing workspace, either the launcher's own or a single label match, and an
adopted workspace's tabs are NEVER inspected or identified as prunable.

-Relationship says whether the container belongs to the SAME firstmate home as the
caller:
  launcher-home - a crewmate or scout for the caller's own home. When the caller
                  is itself running in a herdr pane, the worker MUST land in that
                  exact workspace, never in whichever same-labeled workspace
                  happens to sort first.
  other-home    - a --secondmate launch, which stands up a DIFFERENT home's own
                  per-home workspace by design; the launcher's workspace is
                  deliberately not inherited.

With no herdr ancestry the per-home label lookup is the resolver - but it must
then resolve to exactly ONE workspace. Two same-labeled home workspaces with no
launcher identity to disambiguate them is an unresolvable placement, and adopting
either is the very defect this refuses.

--no-focus: verified that workspace create does NOT focus by default once at
least one workspace exists; the ONE exception is the very first workspace in a
brand-new session, which focuses regardless (herdr always needs something focused
to attach to). The flag is passed unconditionally for defense in depth.
#>
function Initialize-FmBackendHerdrWorkspace {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Relationship = 'launcher-home'
    )

    if ([string]::IsNullOrEmpty($Relationship)) { $Relationship = 'launcher-home' }
    if ($Relationship -ceq 'launcher-home') {
        $identity = Get-FmBackendHerdrLauncherIdentity $Session
        if ($identity.Code -eq 0) {
            return @{ Code = 0; WorkspaceId = $identity.WorkspaceId; SeededTabId = '' }
        }
        if ($identity.Code -ne 2) {
            return @{ Code = 3; WorkspaceId = ''; SeededTabId = '' }
        }
    }

    $label = Get-FmBackendHerdrWorkspaceLabel
    $matched = @(Get-FmBackendHerdrWorkspaceMatch $Session)
    $nonEmpty = @($matched | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -gt 1) {
        $joined = ($nonEmpty -join ' ')
        Write-FmErr "error: $($nonEmpty.Count) herdr workspaces in session '$Session' are labeled '$label' ($joined) and this spawn has no herdr parent pane to identify which one is its own; rename or close the extras, or run firstmate inside the workspace its workers belong in"
        return @{ Code = 3; WorkspaceId = ''; SeededTabId = '' }
    }
    if ($matched.Count -ge 1 -and -not [string]::IsNullOrEmpty($matched[0])) {
        return @{ Code = 0; WorkspaceId = $matched[0]; SeededTabId = '' }
    }

    $out = Invoke-FmBackendHerdrCli -Session $Session -Arguments @(
        'workspace', 'create', '--cwd', $WorkingDirectory, '--label', $label, '--no-focus')
    if (-not $out.Ok) { return @{ Code = 1; WorkspaceId = ''; SeededTabId = '' } }
    $doc = ConvertFrom-FmBackendHerdrJson $out.StdOut
    $wsid = Get-FmBackendHerdrJsonString $doc @('result', 'workspace', 'workspace_id')
    if ([string]::IsNullOrEmpty($wsid)) { return @{ Code = 1; WorkspaceId = ''; SeededTabId = '' } }

    # Herdr seeds a new workspace with one auto-created default tab firstmate
    # never uses. It is NOT pruned here: at this instant it is the workspace's
    # ONLY tab, and closing a workspace's last tab deletes the workspace itself
    # (verified against the real binary) - pruning here would destroy the
    # workspace just created. New-FmBackendHerdrTask prunes it instead, once the
    # first real task tab exists alongside it, and only ever targets this exact
    # captured tab id.
    $seeded = Get-FmBackendHerdrJsonString $doc @('result', 'tab', 'tab_id')
    return @{ Code = 0; WorkspaceId = $wsid; SeededTabId = $seeded }
}

<#
.SYNOPSIS
The full spawn-time container-ensure sequence: version gate, server, workspace.
.DESCRIPTION
Twin of fm_backend_herdr_container_ensure. Echoes
"<session>:<workspace_id><TAB><seeded_default_tab_id>" - a single TAB always
separates the two fields, and the second is EMPTY for an adopted workspace. The
seeded tab id must be threaded through to New-FmBackendHerdrTask, which is the
only function allowed to prune it.

Returns $null on failure. A refusal from the workspace resolver already reported
the exact placement it would not guess at, so no generic message is added on top
of it - adding one would bury it.
#>
function Initialize-FmBackendHerdrContainer {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorkingDirectory = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Relationship = 'launcher-home'
    )

    if ([string]::IsNullOrEmpty($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
    if (-not (Test-FmBackendHerdrVersion)) { return $null }
    $session = Get-FmBackendHerdrSession
    if (-not (Initialize-FmBackendHerdrServer $session)) { return $null }

    $ensured = Initialize-FmBackendHerdrWorkspace -Session $session -WorkingDirectory $WorkingDirectory `
        -Relationship $Relationship
    if ($ensured.Code -eq 3) { return $null }
    if ($ensured.Code -ne 0 -or [string]::IsNullOrEmpty($ensured.WorkspaceId)) {
        $label = Get-FmBackendHerdrWorkspaceLabel
        Write-FmErr "error: failed to ensure herdr workspace '$label' in session '$session'"
        return $null
    }
    return "$session`:$($ensured.WorkspaceId)$($script:FmHerdrTab)$($ensured.SeededTabId)"
}

<#
.SYNOPSIS
The root pane id for a tab, via one pane-list call filtered by tab id.
.DESCRIPTION
Twin of fm_backend_herdr_pane_for_tab. Never assumes a tab-number/pane-number
correspondence - herdr numbers them independently.
#>
function Get-FmBackendHerdrPaneForTab {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabId
    )

    $panes = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $WorkspaceId)
    if (-not $panes.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $panes.StdOut
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'panes'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'tab_id') -ceq $TabId) {
            return (Get-FmBackendHerdrItemString -Item $item -Key 'pane_id')
        }
    }
    return ''
}

<#
.SYNOPSIS
Create the task's tab (one pane) in a container, replacing a confirmed husk.
.DESCRIPTION
Twin of fm_backend_herdr_create_task. -Container is "session:workspace_id".
Echoes "<tab_id> <pane_id>" on success, $null on failure.

Herdr does NOT enforce label uniqueness (verified: two tabs can share a label), so
the duplicate check is ours, mirroring tmux's manual check. A same-labeled tab
existing is no longer an automatic refusal: herdr persists and restores its whole
session layout across a server restart, and a restored fm-<id> task tab comes back
a HUSK - a dead pane, or a plain agent-less shell sitting in the saved cwd, never
the crewmate that used to be there. Test-FmBackendHerdrTabIsHusk classifies it
conservatively (dead or no-agent only; anything live or ambiguous refuses exactly
as before) and, when it IS a confirmed husk, this CLOSES AND REPLACES it.

ORDERING IS DELIBERATE: the REPLACEMENT tab is created FIRST, and the husk is
closed only AFTER that succeeds - never the reverse. Closing a workspace's LAST
remaining tab deletes the whole workspace on real herdr, and a session-restore
husk can legitimately be that workspace's only tab. Herdr's lack of
label-uniqueness enforcement is exactly what makes this safe: the new and the husk
tab can briefly share a label with no error, so the workspace never drops to zero
tabs.

-SeededDefaultTabId is exactly what this same container-ensure captured, non-empty
ONLY when this spawn's own call just created the workspace. Once the real task tab
exists, it is the ONLY input that may trigger a prune, and it is PASSED by the
caller, never re-derived here from tab list contents or labels.
#>
function New-FmBackendHerdrTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin creates unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Container,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$SeededDefaultTabId = ''
    )

    $colon = $Container.IndexOf(':')
    if ($colon -lt 0) { return $null }
    $session = $Container.Substring(0, $colon)
    $wsid = $Container.Substring($colon + 1)

    $list = Invoke-FmBackendHerdrCli -Session $session -Arguments @('tab', 'list', '--workspace', $wsid)
    if (-not $list.Ok) { return $null }
    $listDoc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'tabs'))) {
        Write-FmErr "error: could not parse herdr tab list output for workspace $wsid (session $session)"
        return $null
    }

    $duplicates = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $listDoc -Path @('result', 'tabs'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'label') -ceq $Label) {
            $duplicates += (Get-FmBackendHerdrItemString -Item $item -Key 'tab_id')
        }
    }
    $huskTabs = @()
    foreach ($dup in $duplicates) {
        if ([string]::IsNullOrEmpty($dup)) { continue }
        $dupPane = Get-FmBackendHerdrPaneForTab -Session $session -WorkspaceId $wsid -TabId $dup
        if ([string]::IsNullOrEmpty($dupPane) -or
            -not (Test-FmBackendHerdrTabIsHusk -Session $session -PaneId $dupPane)) {
            Write-FmErr "error: herdr tab '$Label' already exists in workspace $wsid (session $session)"
            return $null
        }
        $huskTabs += $dup
    }

    $out = Invoke-FmBackendHerdrCli -Session $session -Arguments @(
        'tab', 'create', '--workspace', $wsid, '--cwd', $WorkingDirectory, '--label', $Label, '--no-focus')
    if (-not $out.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $out.StdOut
    $tabId = Get-FmBackendHerdrJsonString $doc @('result', 'tab', 'tab_id')
    $paneId = Get-FmBackendHerdrJsonString $doc @('result', 'root_pane', 'pane_id')
    if ([string]::IsNullOrEmpty($tabId) -or [string]::IsNullOrEmpty($paneId)) {
        Write-FmErr 'error: could not parse tab/pane id from herdr tab create output'
        return $null
    }

    if (-not (Initialize-FmBackendHerdrPaneShell -Session $session -PaneId $paneId)) { return $null }
    if (-not [string]::IsNullOrEmpty($SeededDefaultTabId)) {
        [void](Remove-FmBackendHerdrSeededDefaultTab -Session $session -WorkspaceId $wsid `
                -SeededTabId $SeededDefaultTabId)
    }

    if ($huskTabs.Count -gt 0) {
        foreach ($dup in $huskTabs) {
            [void](Invoke-FmBackendHerdrCli -Session $session -Arguments @('tab', 'close', $dup))
        }
        $verify = Invoke-FmBackendHerdrCli -Session $session -Arguments @('tab', 'list', '--workspace', $wsid)
        if (-not $verify.Ok) {
            Write-FmErr "error: could not verify herdr husk removal for tab '$Label' in workspace $wsid (session $session)"
            return $null
        }
        $verifyDoc = ConvertFrom-FmBackendHerdrJson $verify.StdOut
        if (-not (Test-FmBackendHerdrJsonArray -Document $verifyDoc -Path @('result', 'tabs'))) {
            Write-FmErr "error: could not parse herdr tab list output for workspace $wsid (session $session)"
            return $null
        }
        $remaining = @()
        foreach ($item in (Get-FmBackendHerdrJsonArray -Document $verifyDoc -Path @('result', 'tabs'))) {
            $id = Get-FmBackendHerdrItemString -Item $item -Key 'tab_id'
            if ((Get-FmBackendHerdrItemString -Item $item -Key 'label') -ceq $Label -and $id -cne $tabId) {
                $remaining += $id
            }
        }
        if ($remaining.Count -gt 0) {
            Write-FmErr "error: failed to remove preexisting herdr tab(s) $($remaining -join ' ') for label '$Label' in workspace $wsid (session $session)"
            return $null
        }
    }

    return "$tabId $paneId"
}

# --- pane bootstrap: the inversion ---------------------------------------------

<#
.SYNOPSIS
Prepare a freshly created pane for the commands this world types into it.
.DESCRIPTION
Twin of fm_backend_herdr_pane_posixify, and a DELIBERATE NO-OP - see divergence 1
in the file header for the full argument.

The bash twin exists because Herdr's Windows build starts every pane in
PowerShell while the BASH tree types POSIX shell syntax into it, so the pane has
to be converted to Git bash first or the spawn is corrupted. A PowerShell-native
firstmate types PowerShell into a PowerShell pane, so the shell the pane already
runs IS the shell the commands are written for and there is nothing to convert.

This is kept as a function rather than deleted so the call sites stay structurally
identical to the bash twin's, the pairing stays greppable, and there is exactly
one place to reverse the decision. It always succeeds, which means no PowerShell
caller can be blocked by a bootstrap it does not need.
#>
function Initialize-FmBackendHerdrPaneShell {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Both parameters are declared and unused ON PURPOSE. This is the no-op twin of fm_backend_herdr_pane_posixify, and keeping its exact signature is what makes the call sites structurally identical to the bash ones and the pairing greppable - which is the whole reason the function was kept rather than deleted.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )
    return $true
}

<#
.SYNOPSIS
Does this adapter expect a PowerShell pane shell?
.DESCRIPTION
The assertable half of divergence 1. Initialize-FmBackendHerdrPaneShell is a
no-op because a PowerShell caller sends PowerShell-syntax pane commands, and that
is a real coupling to the spawn package. Exporting the expectation lets
fm-spawn.ps1 ASSERT it rather than assume it, and gives a future non-Windows
PowerShell host one place to answer differently.
#>
function Test-FmBackendHerdrPaneShellIsPowerShell {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Test-FmWindows)
}

# --- reading a pane -----------------------------------------------------------

<#
.SYNOPSIS
The `tail -n N` twin over a string with no trailing newline.
.DESCRIPTION
Every capture in the bash twin is `$( ... )`-captured (so trailing newlines are
already gone) and then piped through tail, which is why the result carries no
trailing newline either. Reproduced here so a converted caller holds exactly what
a bash caller holds.
#>
function Get-FmBackendHerdrTailLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 1)][int]$Count = 200
    )

    if ($Count -le 0) { return '' }
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $lines = @($Text.Split("`n"))
    if ($lines.Count -le $Count) { return $Text }
    return ($lines[($lines.Count - $Count)..($lines.Count - 1)] -join "`n")
}

<#
.SYNOPSIS
Strip the trailing newlines a bash `$( ... )` capture would have removed.
#>
function Get-FmBackendHerdrCaptured {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.TrimEnd("`n")
}

<#
.SYNOPSIS
Resolve the requested and fetched line bounds for a pane read.
.DESCRIPTION
VERIFIED CLI QUIRK (herdr-verification-p2.md "pane read --lines bug"): `pane read
--source recent --lines N` returns COMPLETELY EMPTY output when N is smaller than
the pane's current viewport height (observed threshold ~23 rows for a
default-sized pane) - it does not clamp to the last N lines, it drops the read
entirely. That silently broke exactly the small bounded reads this adapter relies
on most, including the composer-state guard reads around submit and injection. The
workaround is to always request a generous fetch far above any realistic viewport
height and trim locally.
#>
function Get-FmBackendHerdrCaptureBound {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Lines = '')

    $requested = 200
    if (-not [string]::IsNullOrEmpty($Lines) -and $Lines -match '^[0-9]+$') {
        $requested = [int]$Lines
    }
    $fetch = if ($requested -ge 200) { $requested } else { 200 }
    return @{ Lines = $requested; Fetch = $fetch }
}

<#
.SYNOPSIS
Bounded plain-text pane capture.
.DESCRIPTION
Twin of fm_backend_herdr_capture, mirroring fm-peek.sh's and fm-watch.sh's tmux
capture. `--source recent` is the closest herdr analogue to tmux's
scrollback-bounded capture. Returns $null when the target is unusable or the read
failed - the twin of its non-zero return.

-ExpectedLabel is accepted and ignored: the dispatcher forwards it to every
backend and a CmdletBinding function throws on an argument it did not declare,
while herdr binds its endpoint by recorded pane id, exactly as the bash twin
ignores the extra argument.
#>
function Get-FmBackendHerdrCapture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare, so this parameter must exist; herdr binds its endpoint by recorded pane id and has no label verification to spend it on, exactly as the bash twin ignores the extra argument.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $null }
    $bound = Get-FmBackendHerdrCaptureBound $Lines
    $result = Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @(
        'pane', 'read', $parsed.Pane, '--source', 'recent', '--lines', [string]$bound.Fetch)
    if (-not $result.Ok) { return $null }
    return (Get-FmBackendHerdrTailLine -Text (Get-FmBackendHerdrCaptured $result.StdOut) -Count $bound.Lines)
}

<#
.SYNOPSIS
Bounded ANSI-preserving pane capture, for composer classification.
.DESCRIPTION
Twin of fm_backend_herdr_capture_ansi. The styling is load-bearing: herdr's ANSI
pane read preserves the harness's own de-emphasis, which is how the shared ghost
stripper tells a placeholder from real typed input.
#>
function Get-FmBackendHerdrCaptureAnsi {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = ''
    )

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $null }
    $bound = Get-FmBackendHerdrCaptureBound $Lines
    $result = Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @(
        'pane', 'read', $parsed.Pane, '--source', 'recent', '--lines', [string]$bound.Fetch, '--format', 'ansi')
    if (-not $result.Ok) { return $null }
    return (Get-FmBackendHerdrTailLine -Text (Get-FmBackendHerdrCaptured $result.StdOut) -Count $bound.Lines)
}

<#
.SYNOPSIS
The live FOREGROUND process's cwd, or '' on any error.
.DESCRIPTION
Twin of fm_backend_herdr_current_path. Mirrors tmux's pane_current_path poll used
for worktree-path discovery after `treehouse get`.

VERIFIED PITFALL: `pane get`'s `.result.pane.cwd` is the pane's cwd AT CREATION
TIME - the top-level shell's - and does NOT update when that shell `cd`s or enters
a subshell (as `treehouse get` does). Reading it would make the worktree-discovery
poll never see the pane leave the project directory. `.result.pane.foreground_cwd`
tracks the ACTUALLY RUNNING foreground process's cwd instead, confirmed live
against a real treehouse acquisition.

WINDOWS: the same `pane get` succeeds but foreground_cwd is null on the 0.7.5
previews (reading another process's live cwd needs a PEB read the port does not do
yet), so the injection probe is the fallback, and any non-empty result is
normalized because this build reports Windows drive paths. Newer Windows builds
that learn foreground_cwd win automatically - the probe only fires while the field
stays empty.
#>
function Get-FmBackendHerdrCurrentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return '' }
    $result = Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @('pane', 'get', $parsed.Pane)
    $path = ''
    if ($result.Ok) {
        $path = Get-FmBackendHerdrJsonString (ConvertFrom-FmBackendHerdrJson $result.StdOut) @('result', 'pane', 'foreground_cwd')
    }
    if (-not [string]::IsNullOrEmpty($path)) { return (ConvertTo-FmBackendHerdrHostPath $path) }

    # The injection probe adds CLI calls a scripted fixture set has no responses
    # for; see Test-FmBackendHerdrScriptedCli.
    if (Test-FmBackendHerdrScriptedCli) { return '' }
    if (-not (Test-FmWindows)) { return '' }
    return (Get-FmBackendHerdrCurrentPathProbe -Session $parsed.Session -PaneId $parsed.Pane)
}

<#
.SYNOPSIS
WINDOWS-ONLY cwd fallback: ask the pane's own shell.
.DESCRIPTION
Twin of fm_backend_herdr_current_path_probe.

SAFETY CONTRACT, unchanged: this TYPES INTO THE PANE, so it is only safe while the
pane runs a bare shell. fm-spawn's worktree-discovery poll - the single caller of
current-path across the tree - runs strictly before the harness launch, so
injection is safe by construction there. Do NOT reuse current-path on a pane after
its harness is live on Windows: the probe would type into the agent's composer.

The pane's shell drops its cwd into a token-named FILE instead of echoing it: pane
text capture line-wraps at the terminal width, which would truncate long worktree
paths, while a file round-trip is exact. Two probes are sent, one per shell family
the pane can be running - a POSIX pane answers the printf, a PowerShell pane
answers the Set-Content, and the foreign shell's command just errors harmlessly.
The token is fresh per call, so a stale drop from an earlier probe can never
satisfy this one.

Both drop locations are checked. On a Git-for-Windows host they are the SAME
directory (verified live: Git Bash's /tmp IS PowerShell's $env:TEMP), which is why
the bash twin only needs to read one; reading both here costs nothing and keeps
the probe honest on a host where they diverge.
#>
function Get-FmBackendHerdrCurrentPathProbe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )

    $token = "$PID$([System.Random]::Shared.Next(0, 32768))$([System.Random]::Shared.Next(0, 32768))"
    $leaf = ".fm-herdr-cwd-$token"
    $candidates = @()
    $posixDrop = ConvertTo-FmNativePath "/tmp/$leaf"
    if (-not [string]::IsNullOrEmpty($posixDrop)) { $candidates += $posixDrop }
    try {
        $tempDrop = Join-Path ([System.IO.Path]::GetTempPath()) $leaf
        if ($candidates -notcontains $tempDrop) { $candidates += $tempDrop }
    } catch {
        $null = $_
    }

    $posixCommand = 'printf ''%s'' "$PWD" > /tmp/' + $leaf
    if (-not (Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'run', $PaneId, $posixCommand)).Ok) {
        return ''
    }
    $psCommand = 'Set-Content -LiteralPath "$env:TEMP/' + $leaf + '" -NoNewline -Value ([string]$PWD)'
    [void](Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'run', $PaneId, $psCommand))

    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 200
        foreach ($drop in $candidates) {
            if (-not [System.IO.File]::Exists($drop)) { continue }
            $path = ''
            try { $path = [System.IO.File]::ReadAllText($drop) } catch { $path = '' }
            try { [System.IO.File]::Delete($drop) } catch { $null = $_ }
            if ([string]::IsNullOrEmpty($path)) { return '' }
            return (ConvertTo-FmBackendHerdrHostPath $path)
        }
    }
    foreach ($drop in $candidates) {
        try { if ([System.IO.File]::Exists($drop)) { [System.IO.File]::Delete($drop) } } catch { $null = $_ }
    }
    return ''
}

# --- writing into a pane ------------------------------------------------------

<#
.SYNOPSIS
Send one line of TEXT and submit it, ATOMICALLY.
.DESCRIPTION
Twin of fm_backend_herdr_send_text_line, mirroring tmux's `send-keys -t T text
Enter`. Used for the fixed spawn-time commands; `pane run` types the command and
submits it in one call (verified).
#>
function Send-FmBackendHerdrTextLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $false }
    return [bool](Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @('pane', 'run', $parsed.Pane, $Text)).Ok
}

<#
.SYNOPSIS
Send TEXT as literal, UNSUBMITTED input - the caller sends Enter separately.
.DESCRIPTION
Twin of fm_backend_herdr_send_literal, mirroring tmux's `send-keys -t T -l text`.
Verified: `pane send-text` does NOT auto-submit; it behaves exactly like tmux's
literal send.
#>
function Send-FmBackendHerdrLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $false }
    return [bool](Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @('pane', 'send-text', $parsed.Pane, $Text)).Ok
}

<#
.SYNOPSIS
Map firstmate's key vocabulary onto herdr's `pane send-keys` names.
.DESCRIPTION
Twin of fm_backend_herdr_normalize_key. Verified empirically that enter,
escape/esc and both ctrl+c/C-c work (case-insensitively on herdr's side, but
normalized explicitly rather than relying on that). An unrecognized key is passed
through unchanged, exactly as the bash `*)` arm does.
#>
function ConvertTo-FmBackendHerdrKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Key = '')

    switch -CaseSensitive ($Key) {
        'Enter' { return 'enter' }
        'enter' { return 'enter' }
        'Escape' { return 'escape' }
        'escape' { return 'escape' }
        'Esc' { return 'escape' }
        'esc' { return 'escape' }
        'C-c' { return 'ctrl+c' }
        'c-c' { return 'ctrl+c' }
        'ctrl+c' { return 'ctrl+c' }
        'Ctrl+C' { return 'ctrl+c' }
        # C-u clears a composer line. fm-send's muse interrupt path needs it to
        # drop the prompt muse restores into the composer after Escape.
        'C-u' { return 'ctrl+u' }
        'c-u' { return 'ctrl+u' }
        'ctrl+u' { return 'ctrl+u' }
        'Ctrl+U' { return 'ctrl+u' }
        default { return $Key }
    }
}

<#
.SYNOPSIS
Send one named special key.
.DESCRIPTION
Twin of fm_backend_herdr_send_key, mirroring fm-send.sh's --key path.
-ExpectedLabel is accepted and ignored; see Get-FmBackendHerdrCapture.
#>
function Send-FmBackendHerdrKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare; herdr binds its endpoint by recorded pane id, exactly as the bash twin ignores the extra argument.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $false }
    $normalized = ConvertTo-FmBackendHerdrKey $Key
    return [bool](Invoke-FmBackendHerdrCli -Session $parsed.Session -Arguments @('pane', 'send-keys', $parsed.Pane, $normalized)).Ok
}

# --- native agent state -------------------------------------------------------

<#
.SYNOPSIS
One `agent get` read, echoing the raw agent_status string, or '' on any failure.
.DESCRIPTION
Twin of fm_backend_herdr_agent_status_raw. DELIBERATELY skips the server-ensure
round trip that Get-FmBackendHerdrBusyState pays on every call:
Wait-FmBackendHerdrWorking polls this in a tight loop right after a caller has
already parsed the target and confirmed the server is live, so re-checking
liveness on every poll would add latency without adding safety.
#>
function Get-FmBackendHerdrAgentStatusRaw {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('agent', 'get', $PaneId)
    if (-not $result.Ok) { return '' }
    return (Get-FmBackendHerdrJsonString (ConvertFrom-FmBackendHerdrJson $result.StdOut) @('result', 'agent', 'agent_status'))
}

<#
.SYNOPSIS
The pane's registered agent and status as one TAB-separated record.
.DESCRIPTION
Twin of fm_backend_herdr_agent_identity_raw. Returns $null when the call failed;
otherwise "<agent><TAB><status>", with either half empty when absent - which is
what lets the Pi composer gate distinguish "not Pi" from "identity unreadable".
#>
function Get-FmBackendHerdrAgentIdentityRaw {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = ''
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('agent', 'get', $PaneId)
    if (-not $result.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    $agent = Get-FmBackendHerdrJsonString $doc @('result', 'agent', 'agent')
    $status = Get-FmBackendHerdrJsonString $doc @('result', 'agent', 'agent_status')
    return "$agent$($script:FmHerdrTab)$status"
}

<#
.SYNOPSIS
Map a raw agent_status to the watcher's busy|idle|unknown vocabulary.
.DESCRIPTION
Twin of fm_backend_herdr_classify_agent_status. working -> busy (actively
generating); idle/done -> idle; BLOCKED -> idle, because a blocked agent is stuck
waiting on the human, not grinding, and the watcher should treat it like a stale
pane needing attention rather than suppress it as busy; anything else -> unknown,
the caller's cue to fall back to pane-regex detection.
#>
function Get-FmBackendHerdrAgentStatusClass {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Status = '')

    switch -CaseSensitive ($Status) {
        'working' { return 'busy' }
        'idle' { return 'idle' }
        'done' { return 'idle' }
        'blocked' { return 'idle' }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
Map a raw agent_status to the SUBMIT-confirmation vocabulary.
.DESCRIPTION
Twin of fm_backend_herdr_classify_submit_agent_status. Deliberately different from
the watcher's mapping: for submit confirmation a BLOCKED agent counts as busy,
because reaching a prompt proves the submit landed.
#>
function Get-FmBackendHerdrSubmitStatusClass {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Status = '')

    switch -CaseSensitive ($Status) {
        'working' { return 'busy' }
        'blocked' { return 'busy' }
        'idle' { return 'idle' }
        'done' { return 'idle' }
        default { return 'unknown' }
    }
}

<#
.SYNOPSIS
Semantic busy state from herdr's native agent-state detection.
.DESCRIPTION
Twin of fm_backend_herdr_busy_state - the first backend where the fleet's busy
state gets real semantics. Note the fleet-wide rule this feeds: a native `busy` is
evidence of activity, but a native `idle` is NEVER evidence that a worker has
stopped, because a harness can read idle while it waits on its own long foreground
tool; the task's own semantic busy state decides that.
#>
function Get-FmBackendHerdrBusyState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return 'unknown' }
    return (Get-FmBackendHerdrAgentStatusClass (Get-FmBackendHerdrAgentStatusRaw -Session $parsed.Session -PaneId $parsed.Pane))
}

# --- composer classification --------------------------------------------------
#
# Herdr has NO cursor-row primitive (unlike tmux's #{cursor_y}), so the composer
# is located STRUCTURALLY, recognizing three shapes and keeping whichever match
# comes LAST when scanning forward, so a shape earlier in scrollback or a popup
# can never outrank the real bottom-anchored composer:
#
#   bordered  - a boxed composer (verified grok 0.2.82): the row's TRIMMED content
#               both STARTS and ENDS with the same border glyph. The box's own
#               top/bottom rows use rounded corners, which never match; popup item
#               rows and separators carry no border glyph; the footer help line
#               uses the glyph only as an INTERIOR separator and does not start
#               with one.
#   bare      - an UNBORDERED composer (verified real claude 2.x and codex
#               0.142.x): the row starts with a verified agent prompt glyph and
#               carries no closing border. Both harnesses ALSO render bordered
#               decorative boxes elsewhere, which is why matching EITHER shape and
#               keeping the LAST one is what keeps the live composer winning. The
#               bare shape is deliberately narrower than the bordered classifier
#               so a no-agent shell prompt (> $ % #) falls through to `unknown`
#               rather than being misread as delivered.
#   separated - Pi's composer is one or more content rows between two solid
#               horizontal separator rows, with no prompt glyph or side borders.
#               Accepted ONLY when Herdr's native identity says Pi AND the status
#               is idle, done or blocked. A missing/stale/non-Pi identity, a
#               WORKING Pi, an over-tall candidate or an incomplete separator pair
#               all remain unknown. That identity+structure conjunction is what
#               makes a blank Pi row safe without weakening dead-shell refusal.
#
# A BARE SHELL PROMPT IS NEVER AN EMPTY AGENT COMPOSER, and away-mode injection
# proceeds only on an affirmative `empty`. That is what stops a dead agent pane
# from receiving and possibly EXECUTING an escalation as shell input.

<#
.SYNOPSIS
Split a capture into lines exactly as the bash twin's read loop sees them.
.DESCRIPTION
The bash loop reads from `printf '%s\n' "$cap"`, which appends exactly one
newline to a `$( ... )`-stripped capture. So an EMPTY capture still yields ONE
(empty) line, and the row counter still advances for it - which matters, because
the Pi comparison below is a comparison of ROW NUMBERS.
#>
function Get-FmBackendHerdrCaptureLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '')

    if ($null -eq $Capture) { $Capture = '' }
    $lines = @(($Capture + "`n").Split("`n"))
    return [string[]]@($lines[0..($lines.Count - 2)])
}

# The six ASCII members of the C-locale [[:space:]] - what the bash twin's
# `${var#"${var%%[![:space:]]*}"}` trims. .NET's Trim() would also strip Unicode
# separators, which is a wider set than the oracle removes.
$script:FmHerdrAsciiSpace = [char[]]@(' ', "`t", "`n", [char]11, [char]12, "`r")

function Get-FmBackendHerdrTrimmed {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim($script:FmHerdrAsciiSpace)
}

<#
.SYNOPSIS
Is this plain row one of Pi's solid horizontal separators?
.DESCRIPTION
Twin of fm_backend_herdr_pi_separator_row: at least 8 characters after trimming,
and every remaining character is U+2500 BOX DRAWINGS LIGHT HORIZONTAL.

The minimum width is `${#row}`, which bash measures in CHARACTERS under a UTF-8
locale and in BYTES under LC_ALL=C. The differential oracle host runs
LANG=en_GB.UTF-8 (verified), so characters is the oracle's own answer and is what
this uses.
#>
<#
.SYNOPSIS
True when a plain row is a Pi separator: 8+ rule characters and nothing else.
.DESCRIPTION
KNOWN production divergence on this host, deliberate: bash's `${#row} -ge 8`
counts BYTES under the C-default locale the hooks run in, so each 3-byte
U+2500 counts as three and THREE dashes already satisfy bash's check. This
twin counts CHARACTERS, which is the rule's stated intent ("Unicode width
rule"). The differential pins a UTF-8 locale around the bash oracle call so
the suite asserts the rule; the byte-counting behaviour is a bash-side
environmental defect, not an oracle contract worth copying.
#>
function Test-FmBackendHerdrPiSeparatorRow {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Row = '')

    $trimmed = Get-FmBackendHerdrTrimmed $Row
    if ($trimmed.Length -lt 8) { return $false }
    foreach ($ch in $trimmed.ToCharArray()) {
        if ($ch -ne [char]0x2500) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
Locate the bottom-most COMPLETE pair of Pi separator rows.
.DESCRIPTION
Twin of fm_backend_herdr_pi_composer_find, whose six shell globals become this
hashtable. A separator closes the preceding candidate and immediately opens the
next, so an earlier transcript rule can never outrank the live bottom composer
pair. Returning the content in a hashtable rather than through stdout is also what
keeps an EMPTY composer's content from being lost, which is why the bash twin used
globals here in the first place.

  Found              a complete pair was seen.
  Valid              that pair's content was within the height bound.
  OpenLine / Line    the 1-based row numbers of the pair's opening and closing
                     separators, compared against the generic match's row.
  LastSeparatorLine  the last separator row seen, complete pair or not.
  Content            the raw (styled) rows between the pair.

The content accumulator reproduces one quirk of the bash twin exactly: the
separator is only inserted when the accumulator is already non-empty, so a
candidate whose FIRST row is empty contributes no separator and a pair of empty
rows accumulates as one empty string. Changing that would change what an empty Pi
composer classifies as.
#>
function Get-FmBackendHerdrPiComposer {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '')

    $max = Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES' 8
    if ($max -le 0) { $max = 8 }

    $state = @{
        Found = $false; Valid = $false; OpenLine = 0; Line = 0
        LastSeparatorLine = 0; Content = ''
    }
    $open = $false
    $openRow = 0
    $lines = 0
    $candidate = ''
    $row = 0

    # @( ... ) around the call: PowerShell UNROLLS a single-element array out of a
    # function return, so a one-line capture would arrive as a bare string. foreach
    # happens to iterate that correctly, but the wrap is what makes it true by
    # construction rather than by accident (docs/powershell-port.md).
    foreach ($line in @(Get-FmBackendHerdrCaptureLine $Capture)) {
        $row++
        $plain = Get-FmComposerPlainText $line
        if (Test-FmBackendHerdrPiSeparatorRow $plain) {
            $state.LastSeparatorLine = $row
            if ($open) {
                $state.Found = $true
                $state.OpenLine = $openRow
                $state.Line = $row
                if ($lines -le $max) {
                    $state.Valid = $true
                    $state.Content = $candidate
                } else {
                    $state.Valid = $false
                    $state.Content = ''
                }
            }
            $open = $true
            $openRow = $row
            $lines = 0
            $candidate = ''
        } elseif ($open) {
            if (-not [string]::IsNullOrEmpty($candidate)) { $candidate += "`n" }
            $candidate += $line
            $lines++
        }
    }
    return $state
}

<#
.SYNOPSIS
Read a TAB record the way `IFS=$'\t' read -r a b` reads it.
.DESCRIPTION
TAB is IFS WHITESPACE, so `read` strips leading and trailing tabs and collapses
runs - the opposite of the empty-field-preserving `cut` used on the event stream.
The agent-identity record is genuinely read that way by the bash twin, and the
collapse is load-bearing: an empty agent field makes "<TAB>idle" read as
agent="idle", which then falls through to the keep-generic arm rather than the
refuse arm. Reproduced here rather than corrected.
#>
function Get-FmBackendHerdrIfsPair {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Record = '')

    $line = if ($null -eq $Record) { '' } else { $Record }
    $line = $line.Trim([char[]]@("`t"))
    if ([string]::IsNullOrEmpty($line)) { return [string[]]@('', '') }
    $tab = $line.IndexOf("`t")
    if ($tab -lt 0) { return [string[]]@($line, '') }
    $rest = $line.Substring($tab + 1).TrimStart([char[]]@("`t"))
    return [string[]]@($line.Substring(0, $tab), $rest)
}

<#
.SYNOPSIS
Classify a target's composer row as empty|pending|unknown.
.DESCRIPTION
Twin of fm_backend_herdr_composer_state. See the section header for the three
shapes and why the LAST match wins.

  empty   - blank, a bare prompt glyph, known ghost/placeholder text, or only
            de-emphasised ANSI ghost text recognized by the shared extractor.
            Safe to treat as submitted.
  pending - real, unsubmitted text sits in the composer. This deliberately also
            covers a slash-command popup that only auto-completed or filled an
            argument hint into the composer - that first Enter was a SELECTION,
            not a submission.
  unknown - the pane could not be read, or no composer row of any shape was found.

Content extraction goes through bin/fm-composer-lib.psm1's shared ANSI-aware
extractor, which drops dim/faint AND dark-truecolor ghost runs. That shared owner
is why the tmux and herdr backends cannot drift; it superseded a herdr-only faint
byte-pattern check that recognized only Codex's bold-wrapped bare prompt and
missed claude's own dim ghost - the overnight away-mode injection wedge. In a dark
theme it also drops the composer's own dark box border, which is exactly why the
bordered flag is read from the PLAIN shape above, not from this stripped content.
#>
function Get-FmBackendHerdrComposerState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) { return 'unknown' }

    $composerLines = [string](Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_COMPOSER_LINES' 20)
    $capture = Get-FmBackendHerdrCaptureAnsi -Target $Target -Lines $composerLines
    if ($null -eq $capture) {
        $capture = Get-FmBackendHerdrCapture -Target $Target -Lines $composerLines
    }
    if ($null -eq $capture) { return 'unknown' }

    $barePattern = Get-FmEnv -Name 'FM_BACKEND_HERDR_BARE_PROMPT_RE' -Default "^($([char]0x276F)|$([char]0x203A))"
    $bareRegex = $null
    try {
        $bareRegex = [System.Text.RegularExpressions.Regex]::new($barePattern)
    } catch {
        $bareRegex = $null
    }

    $found = $false
    $shape = ''
    $rawMatch = ''
    $genericLine = 0
    $row = 0
    foreach ($line in @(Get-FmBackendHerdrCaptureLine $capture)) {
        $row++
        $trimmed = Get-FmBackendHerdrTrimmed (Get-FmComposerPlainText $line)
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        if (Test-FmBackendHerdrBorderedRow $trimmed) {
            $shape = 'bordered'
            $rawMatch = $line
            $genericLine = $row
            $found = $true
        } elseif ($null -ne $bareRegex -and $bareRegex.IsMatch($trimmed)) {
            $shape = 'bare'
            $rawMatch = $line
            $genericLine = $row
            $found = $true
        }
    }

    # Pi has no prompt glyph or side border. Compare its bottom-most complete
    # separator pair with the last generic match so an earlier bordered transcript
    # row can never suppress the live Pi composer. Identity is consulted ONLY when
    # a lower separator pair could change the verdict - which keeps the extra
    # `agent get` off every other composer read.
    $pi = Get-FmBackendHerdrPiComposer $capture
    if ($pi.Found -and $pi.Line -gt $genericLine -and $genericLine -lt $pi.OpenLine) {
        $identity = Get-FmBackendHerdrAgentIdentityRaw -Session $parsed.Session -PaneId $parsed.Pane
        if ($null -eq $identity) { $identity = '' }
        $pair = Get-FmBackendHerdrIfsPair $identity
        $agent = $pair[0]
        $status = $pair[1]
        if ($agent -ceq 'pi' -and ($status -ceq 'idle' -or $status -ceq 'done' -or $status -ceq 'blocked')) {
            if ($pi.Valid) {
                $shape = 'separated'
                $rawMatch = $pi.Content
                $found = $true
            } else {
                $found = $false
            }
        } elseif ($agent -ceq 'pi' -or [string]::IsNullOrEmpty($agent)) {
            # A working Pi or an unreadable identity cannot authorize injection,
            # and the lower separator pair proves any generic row above is stale.
            $found = $false
        }
        # A known non-Pi agent keeps its established generic verdict.
    } elseif (-not $pi.Found -and $pi.LastSeparatorLine -gt $genericLine) {
        # A lower UNMATCHED separator proves the generic row is stale, but does
        # not provide the complete Pi structure required for injection.
        $found = $false
    }

    if (-not $found) { return 'unknown' }

    $stripped = Get-FmBackendHerdrTrimmed (Get-FmComposerRealText ($rawMatch + "`n"))
    $bordered = '0'
    if ($shape -ceq 'bordered') {
        $bordered = '1'
        $stripped = Get-FmBackendHerdrTrimmed ($stripped -replace "[$([char]0x2502)$([char]0x2503)|]", '')
    } elseif ($shape -ceq 'separated') {
        # The native Pi identity plus the complete separator pair IS the genuine
        # composer container, equivalent to a bordered box for shared content
        # classification.
        $bordered = '1'
    }

    $idleRegex = Get-FmEnv -Name 'FM_BACKEND_HERDR_IDLE_RE' -Default '^Type a message\.\.\.$'
    return (Get-FmComposerContentState -Bordered $bordered -Content $stripped -IdleRegex $idleRegex)
}

<#
.SYNOPSIS
Does this trimmed row both start and end with the same composer border glyph?
.DESCRIPTION
The `case "$trimmed" in '│'*'│'|'┃'*'┃'|'|'*'|')` twin. The glob needs at least
two glyphs, so a lone border character is not a bordered row.
#>
function Test-FmBackendHerdrBorderedRow {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Row = '')

    if ([string]::IsNullOrEmpty($Row) -or $Row.Length -lt 2) { return $false }
    foreach ($glyph in @([char]0x2502, [char]0x2503, [char]'|')) {
        if ($Row[0] -eq $glyph -and $Row[$Row.Length - 1] -eq $glyph) { return $true }
    }
    return $false
}

# --- verified submit ----------------------------------------------------------

<#
.SYNOPSIS
Parse a number the way awk coerces one, taking any leading numeric prefix.
.DESCRIPTION
`b += 0` in awk yields 0 for a non-numeric string and 0.5 for "0.5abc". The bash
twin passes caller-supplied strings straight into awk, so the coercion is part of
the behavior rather than an accident.
#>
function ConvertTo-FmBackendHerdrAwkNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return 0.0 }
    $match = [System.Text.RegularExpressions.Regex]::Match($Text,
        '^[ \t]*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?')
    if (-not $match.Success) { return 0.0 }
    $value = 0.0
    if (-not [double]::TryParse($match.Value.Trim(), [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return 0.0
    }
    return $value
}

<#
.SYNOPSIS
The per-Enter confirmation budget, floored at the configured minimum.
.DESCRIPTION
Twin of fm_backend_herdr_submit_confirm_budget, formatted "%.4f" exactly as awk
prints it so a caller comparing the string sees the same value.
#>
function Get-FmBackendHerdrSubmitConfirmBudget {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Budget = '')

    $b = ConvertTo-FmBackendHerdrAwkNumber $Budget
    $m = ConvertTo-FmBackendHerdrAwkNumber (Get-FmEnv -Name 'FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP' -Default '0.6')
    if ($b -lt 0) { $b = 0.0 }
    if ($m -lt 0) { $m = 0.0 }
    if ($m -gt $b) { $b = $m }
    return $b.ToString('F4', [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
Poll a pane's native agent state across a budget, returning the STRONGEST signal.
.DESCRIPTION
Twin of fm_backend_herdr_wait_for_working.

  busy    - a submit-active status was observed at least once: confirmation that a
            real turn started or reached a prompt, INDEPENDENT of whatever the
            composer's own text happens to show. Returned the INSTANT it is seen,
            without waiting out the rest of the budget.
  idle    - the target was legibly read at least once and never reported busy
            across the whole window: a genuine "not (yet) submitted", not a read
            failure. The caller retries Enter on this verdict.
  unknown - EVERY poll failed to read the target at all (a hard I/O failure - pane
            gone, socket error - not a timing race). The caller must not keep
            retrying Enter against a target it cannot even read.

Spreading <Polls> samples across the budget rather than checking once at the end
is what makes this robust against a SLOW transition. Real claude and codex were
measured first-working at 90-490ms after Enter, comfortably inside a
several-hundred-ms multiply-sampled window. The residual gap - a turn so fast it
starts AND returns to idle between two samples - is bounded by how tightly the
polls are packed and has not been observed; on that unobserved chance the verdict
is `pending` and the caller only re-sends ENTER, never retypes, so it lands on an
already-empty composer as a no-op rather than a duplicate delivery.
#>
function Wait-FmBackendHerdrWorking {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Budget = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Polls = ''
    )

    $pollCount = 1
    if (-not [string]::IsNullOrEmpty($Polls) -and $Polls -match '^[0-9]+$' -and [int]$Polls -gt 0) {
        $pollCount = [int]$Polls
    }
    $divisor = $pollCount - 1
    if ($divisor -lt 1) { $divisor = 1 }
    $interval = (ConvertTo-FmBackendHerdrAwkNumber $Budget) / $divisor
    if ($interval -lt 0) { $interval = 0.0 }
    $intervalText = $interval.ToString('F4', [System.Globalization.CultureInfo]::InvariantCulture)

    $sawIdle = $false
    for ($i = 0; $i -lt $pollCount; $i++) {
        if ($pollCount -eq 1 -or $i -gt 0) { Start-FmBackendHerdrSleep $intervalText }
        $raw = Get-FmBackendHerdrAgentStatusRaw -Session $Session -PaneId $PaneId
        switch -CaseSensitive (Get-FmBackendHerdrSubmitStatusClass $raw) {
            'busy' { return 'busy' }
            'idle' { $sawIdle = $true }
            default { }
        }
    }
    if ($sawIdle) { return 'idle' }
    return 'unknown'
}

<#
.SYNOPSIS
Type text once, then submit and verify, retrying ONLY the submission.
.DESCRIPTION
Twin of fm_backend_herdr_send_text_submit. Echoes empty|pending|unknown|send-failed,
a subset of the proof-carrying submit vocabulary. `empty` means confirmed
submitted for every backend; HOW each backend confirms it is an internal decision,
and herdr's is no longer literally "the composer read empty".

CONFIRMATION SIGNAL (rewritten for the 2026-07-07 redelivery incident, which
itself superseded a delta-based check from 2026-07-03): when the target is legibly
IDLE before Enter, submission is confirmed by observing a submit-active
agent_status after Enter, NOT by reading the composer's own row. That makes the
normal confirmation path cross-agent - the same semantic signal regardless of what
text a harness's idle composer happens to display. Composer content is retained
for the not-legibly-idle baseline and for the away-mode daemon's separate
PRE-injection guard.

It also still handles the earlier popup incident with no popup-specific logic at
all: filling a composer placeholder never starts a turn, so agent_status simply
never reports working for that Enter and the loop sends a second one.

THE TEXT IS TYPED EXACTLY ONCE. Only Enter is retried; a twin that retyped would
deliver a captain instruction twice into a live agent.

-ExpectedLabel is accepted and ignored; see Get-FmBackendHerdrCapture.
#>
function Send-FmBackendHerdrTextSubmit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare; herdr binds its endpoint by recorded pane id, exactly as the bash twin ignores the extra argument.')]
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

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) { return 'unknown' }
    if (-not (Send-FmBackendHerdrLiteral -Target $Target -Text $Text)) { return 'send-failed' }
    Start-FmBackendHerdrSleep $Settle

    $baseline = Get-FmBackendHerdrSubmitStatusClass (Get-FmBackendHerdrAgentStatusRaw -Session $parsed.Session -PaneId $parsed.Pane)
    $confirmSleep = Get-FmBackendHerdrSubmitConfirmBudget $EnterSleep
    $polls = [string](Get-FmBackendHerdrIntKnob 'FM_BACKEND_HERDR_SUBMIT_POLLS' 6)

    $retryBudget = 0
    if (-not [string]::IsNullOrEmpty($Retries) -and $Retries -match '^[0-9]+$') { $retryBudget = [int]$Retries }

    $attempt = 0
    while ($true) {
        [void](Send-FmBackendHerdrKey -Target $Target -Key 'Enter')
        $verdict = ''
        if ($baseline -ceq 'idle') {
            $verdict = Wait-FmBackendHerdrWorking -Session $parsed.Session -PaneId $parsed.Pane `
                -Budget $confirmSleep -Polls $polls
        } else {
            Start-FmBackendHerdrSleep $EnterSleep
            $verdict = Get-FmBackendHerdrComposerState $Target
        }
        switch -CaseSensitive ($verdict) {
            'busy' { return 'empty' }
            'empty' { return 'empty' }
            'unknown' { return 'unknown' }
            default { }
        }
        $attempt++
        if ($attempt -ge $retryBudget) { return 'pending' }
    }
}

# --- removing a task endpoint -------------------------------------------------

<#
.SYNOPSIS
The lock-holding half of the task kill.
.DESCRIPTION
Twin of fm_backend_herdr_kill_serialized. When the close would empty a NON-FOCUSED
workspace, Herdr 0.7.5's explicit close moves focus to that workspace's neighbor
with no restore anywhere in this path, so the kill follows the same focus-safe
removal plan as projected cleanup, keeping the exact-tab restore as the backstop.
A close that empties the FOCUSED workspace moves focus legitimately, and every
in-lock planning ambiguity or failure falls back to the plain close, matching the
pre-hardening contract.
#>
function Remove-FmBackendHerdrTargetSerialized {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin closes unconditionally under its caller''s lock; a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )

    $before = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if (-not [string]::IsNullOrEmpty($before)) {
        $split = $before.IndexOf($script:FmHerdrTab)
        $focusedWorkspace = $before.Substring(0, $split)
        $activeTab = $before.Substring($split + 1)

        $info = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'get', $PaneId)
        $doc = if ($info.Ok) { ConvertFrom-FmBackendHerdrJson $info.StdOut } else { $null }
        $targetPane = Get-FmBackendHerdrJsonString $doc @('result', 'pane', 'pane_id')
        $targetTab = Get-FmBackendHerdrJsonString $doc @('result', 'pane', 'tab_id')
        $targetWorkspace = Get-FmBackendHerdrJsonString $doc @('result', 'pane', 'workspace_id')

        if ($targetPane -ceq $PaneId -and -not [string]::IsNullOrEmpty($targetTab) -and $targetTab -cne $activeTab) {
            $plan = Get-FmBackendHerdrEmptyingClosePlan -Session $Session -PaneId $PaneId `
                -WorkspaceId $targetWorkspace -TabId $targetTab -FocusedWorkspaceId $focusedWorkspace
            $closeFailed = $false
            if ($plan.Plan -ceq 'death') {
                if (-not (Close-FmBackendHerdrPaneByDeath -Session $Session -PaneId $PaneId -ShellPid $plan.ShellPid) -and
                    -not (Close-FmBackendHerdrPaneExplicit -Session $Session -PaneId $PaneId)) {
                    $closeFailed = $true
                }
            } elseif (-not (Close-FmBackendHerdrPaneExplicit -Session $Session -PaneId $PaneId)) {
                $closeFailed = $true
            }
            if (-not $closeFailed -and -not [string]::IsNullOrEmpty($plan.MoveRecord)) {
                if ((Get-FmBackendHerdrWorkspacePresenceState -Session $Session -WorkspaceId $targetWorkspace) -cne 'dead') {
                    Write-FmErr 'warning: herdr task kill did not confirm removal of the repositioned workspace'
                    $closeFailed = $true
                }
            }
            if ($closeFailed) { [void](Restore-FmBackendHerdrEmptyingMove $plan.MoveRecord) }
            [void](Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $before -Operation 'task kill')
            return $true
        }
    }
    [void](Close-FmBackendHerdrPaneExplicit -Session $Session -PaneId $PaneId)
    return $true
}

<#
.SYNOPSIS
Remove the task's pane, best-effort and under the session presentation lock.
.DESCRIPTION
Twin of fm_backend_herdr_kill. Verified: closing a tab's only pane closes the tab
too, so a separate tab close is unnecessary.

Task cleanup acquires the session lock BEFORE the task's isolated copy is
returned, so a contended lock refuses up front while the copy, every durable
record and the endpoint are all intact for a plain rerun. An UNLOCKED close is
refused rather than attempted.

Always returns $true, exactly as the bash twin always exits 0: a nonexistent or
already-gone target is not an error here, and Test-FmBackendHerdrEndpointGone is
the separate, structured gate that decides whether durable records may be erased.
#>
function Remove-FmBackendHerdrTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is a dispatcher-facing helper whose bash twin closes unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $parsed = Test-FmBackendHerdrTargetReady $Target
    if ($null -eq $parsed) { return $true }

    $lockPath = Get-FmBackendHerdrPresentationSessionLockPath $parsed.Session
    $held = $false
    if (-not [string]::IsNullOrEmpty($lockPath)) {
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            if (Request-FmLock -LockPath $lockPath) { $held = $true; break }
            Start-Sleep -Milliseconds 100
        }
    }
    if ($held) {
        try {
            [void](Remove-FmBackendHerdrTargetSerialized -Session $parsed.Session -PaneId $parsed.Pane)
        } finally {
            Unlock-FmLock -LockPath $lockPath
        }
    } else {
        Write-FmErr 'warning: herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close'
    }
    return $true
}

# --- discovery ----------------------------------------------------------------

<#
.SYNOPSIS
The live-tab-listing fallback for an ad hoc selector with no metadata.
.DESCRIPTION
Twin of fm_backend_herdr_resolve_bare_selector, mirroring tmux's list-windows
grep. Searches every RUNNING named herdr session, because herdr sessions are not
addressed by one ambient server the way a single tmux server is. Rare in practice
(herdr tasks normally carry metadata), best-effort. Returns "session:pane" or
$null after writing the same refusal.
#>
function Resolve-FmBackendHerdrBareSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $sessions = @()
    if ($herdr) {
        $listing = Invoke-FmTool -FilePath $herdr.Source -Arguments @('session', 'list', '--json')
        if ($listing.Ok) {
            $doc = ConvertFrom-FmBackendHerdrJson $listing.StdOut
            foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('sessions'))) {
                if (-not (Test-FmBackendHerdrItemTrue -Item $item -Key 'running')) { continue }
                $name = Get-FmBackendHerdrItemString -Item $item -Key 'name'
                if (-not [string]::IsNullOrEmpty($name)) { $sessions += $name }
            }
        }
    }

    foreach ($session in $sessions) {
        $tabs = Invoke-FmBackendHerdrCli -Session $session -Arguments @('tab', 'list')
        if (-not $tabs.Ok) { continue }
        $doc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut
        $tabId = ''
        $wsid = ''
        foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'tabs'))) {
            if ((Get-FmBackendHerdrItemString -Item $item -Key 'label') -ceq $Name) {
                $tabId = Get-FmBackendHerdrItemString -Item $item -Key 'tab_id'
                break
            }
        }
        if ([string]::IsNullOrEmpty($tabId)) { continue }
        foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'tabs'))) {
            if ((Get-FmBackendHerdrItemString -Item $item -Key 'tab_id') -ceq $tabId) {
                $wsid = Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id'
                break
            }
        }
        if ([string]::IsNullOrEmpty($wsid)) { continue }
        $paneId = Get-FmBackendHerdrPaneForTab -Session $session -WorkspaceId $wsid -TabId $tabId
        if ([string]::IsNullOrEmpty($paneId)) { continue }
        return "$session`:$paneId"
    }

    Write-FmErr "error: no herdr tab named $Name in any running session"
    return $null
}

<#
.SYNOPSIS
Recovery and orphan discovery: every live fm-<id> task tab in THIS home's workspace.
.DESCRIPTION
Twin of fm_backend_herdr_list_live. Lists by LABEL, never by trusting a stored
pane id, since ids are not guaranteed stable across every server lifecycle. Scoped
to THIS HOME'S OWN workspace - never another home's - which a caller gets for free
because FM_HOME already names it. Read-only: a session or workspace that does not
exist yet simply lists nothing.

One "<session>:<pane_id><TAB><label>" record per live task tab.
#>
function Get-FmBackendHerdrLiveTask {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $wsid = Get-FmBackendHerdrWorkspace $Session
    if ([string]::IsNullOrEmpty($wsid)) { return @() }
    $tabs = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $wsid)
    if (-not $tabs.Ok) { return @() }
    $doc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut

    $records = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'tabs'))) {
        $label = Get-FmBackendHerdrItemString -Item $item -Key 'label'
        if (-not $label.StartsWith('fm-', $script:FmHerdrOrdinal)) { continue }
        $tabId = Get-FmBackendHerdrItemString -Item $item -Key 'tab_id'
        if ([string]::IsNullOrEmpty($tabId)) { continue }
        $paneId = Get-FmBackendHerdrPaneForTab -Session $Session -WorkspaceId $wsid -TabId $tabId
        if ([string]::IsNullOrEmpty($paneId)) { continue }
        $records += "$Session`:$paneId$($script:FmHerdrTab)$label"
    }
    return [string[]]$records
}

# --- the disposable presentation projection -----------------------------------
#
# PRESENTATION IS A BEST-EFFORT VISUAL PROJECTION, NEVER TASK OWNERSHIP OR
# LIFECYCLE AUTHORITY. Neither the token, the title, nor the journal authorizes
# send, capture, task ownership, Treehouse return, or general recovery. Normal
# task metadata remains the sole endpoint authority after creation.

# The label grammars the ordering and binding checks recognize. Kept as compiled
# patterns rather than inline strings so the new-format and legacy-format rules
# have one definition each - they appear in three separate checks below.
$script:FmHerdrNewChildPattern = "^$([char]0x2514) .+ $([char]0x00B7) p:[A-Za-z0-9_-]{22}$"
$script:FmHerdrLegacyChildPattern = "^(firstmate|2ndmate-[^/]+)/.+ $([char]0x00B7) p:[A-Za-z0-9_-]{22}$"
$script:FmHerdrTopLevelParentPattern = '^2ndmate-[^/]+$'

function Test-FmBackendHerdrNewChildLabel {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')
    if ([string]::IsNullOrEmpty($Label)) { return $false }
    return ($Label -cmatch $script:FmHerdrNewChildPattern)
}

function Test-FmBackendHerdrLegacyChildLabel {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')
    if ([string]::IsNullOrEmpty($Label)) { return $false }
    return ($Label -cmatch $script:FmHerdrLegacyChildPattern)
}

function Test-FmBackendHerdrTopLevelParentLabel {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '')
    if ([string]::IsNullOrEmpty($Label)) { return $false }
    if ($Label -ceq 'firstmate') { return $true }
    return ($Label -cmatch $script:FmHerdrTopLevelParentPattern)
}

<#
.SYNOPSIS
Create one disposable presentation workspace and its normal fm-<id> task tab.
.DESCRIPTION
Twin of fm_backend_herdr_projection_create_task, whose seven shell globals become
this hashtable. The caller MUST have atomically published the projection journal
first. Nothing here looks up, adopts or reuses any existing workspace.

  Ok            every step succeeded and the workspace converged to one task pane.
  CleanupSafe   becomes $true only after BOTH creates returned complete exact ids.
                A missing, failed or malformed create response stays ambiguous and
                grants NO cleanup authority - which is what stops an abort from
                closing something this call did not create.

Focus is captured before and verified after EVERY mutation, and a mutation that
did not preserve exact active focus quarantines the journal rather than continuing.
#>
function New-FmBackendHerdrProjectionTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal helper whose bash twin creates unconditionally; a confirmation surface would diverge from the twin and could strand a published journal with no projection.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$WorkingDirectory,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$WorkspaceLabel,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$TaskLabel
    )

    $state = @{
        Ok = $false; Session = ''; WorkspaceId = ''; SeededTabId = ''
        SeededPaneId = ''; TabId = ''; PaneId = ''; CleanupSafe = $false
    }

    if (-not (Test-FmBackendHerdrVersion)) { return $state }
    $session = Get-FmBackendHerdrSession
    if (-not (Initialize-FmBackendHerdrServer $session)) { return $state }

    $focusBefore = Get-FmBackendHerdrProjectionFocusSnapshot $session
    if ([string]::IsNullOrEmpty($focusBefore)) {
        Write-FmErr 'error: herdr presentation workspace create could not capture exact active workspace and tab; refusing a focus-unsafe projection'
        return $state
    }
    $out = Invoke-FmBackendHerdrCli -Session $session -Arguments @(
        'workspace', 'create', '--cwd', $WorkingDirectory, '--label', $WorkspaceLabel, '--no-focus')
    if (-not $out.Ok) {
        [void](Restore-FmBackendHerdrProjectionFocus -Session $session -Before $focusBefore -Operation 'workspace create')
        Write-FmErr 'error: herdr presentation workspace create failed ambiguously; leaving its journal quarantined'
        return $state
    }
    if (-not (Restore-FmBackendHerdrProjectionFocus -Session $session -Before $focusBefore -Operation 'workspace create')) {
        Write-FmErr 'error: herdr presentation workspace create did not preserve exact active focus; leaving its journal quarantined'
        return $state
    }

    $doc = ConvertFrom-FmBackendHerdrJson $out.StdOut
    $state.Session = $session
    $state.WorkspaceId = Get-FmBackendHerdrJsonString $doc @('result', 'workspace', 'workspace_id')
    $state.SeededTabId = Get-FmBackendHerdrJsonString $doc @('result', 'tab', 'tab_id')
    $state.SeededPaneId = Get-FmBackendHerdrJsonString $doc @('result', 'root_pane', 'pane_id')
    if ([string]::IsNullOrEmpty($state.WorkspaceId) -or [string]::IsNullOrEmpty($state.SeededTabId) -or
        [string]::IsNullOrEmpty($state.SeededPaneId)) {
        Write-FmErr 'error: herdr presentation workspace create returned incomplete IDs; leaving its journal quarantined'
        return $state
    }

    $focusBefore = Get-FmBackendHerdrProjectionFocusSnapshot $session
    if ([string]::IsNullOrEmpty($focusBefore)) {
        Write-FmErr 'error: herdr presentation task-tab create could not capture exact active workspace and tab; refusing a focus-unsafe projection'
        return $state
    }
    $out = Invoke-FmBackendHerdrCli -Session $session -Arguments @(
        'tab', 'create', '--workspace', $state.WorkspaceId, '--cwd', $WorkingDirectory,
        '--label', $TaskLabel, '--no-focus')
    if (-not $out.Ok) {
        [void](Restore-FmBackendHerdrProjectionFocus -Session $session -Before $focusBefore -Operation 'task-tab create')
        Write-FmErr 'error: herdr presentation task-tab create failed ambiguously; leaving its journal quarantined'
        return $state
    }
    if (-not (Restore-FmBackendHerdrProjectionFocus -Session $session -Before $focusBefore -Operation 'task-tab create')) {
        Write-FmErr 'error: herdr presentation task-tab create did not preserve exact active focus; leaving its journal quarantined'
        return $state
    }
    $doc = ConvertFrom-FmBackendHerdrJson $out.StdOut
    $state.TabId = Get-FmBackendHerdrJsonString $doc @('result', 'tab', 'tab_id')
    $state.PaneId = Get-FmBackendHerdrJsonString $doc @('result', 'root_pane', 'pane_id')
    if ([string]::IsNullOrEmpty($state.TabId) -or [string]::IsNullOrEmpty($state.PaneId)) {
        Write-FmErr 'error: herdr presentation task-tab create returned incomplete IDs; leaving its journal quarantined'
        return $state
    }
    if (-not (Initialize-FmBackendHerdrPaneShell -Session $session -PaneId $state.PaneId)) {
        Write-FmErr 'error: herdr presentation task pane never reached a POSIX shell; leaving its journal quarantined'
        return $state
    }
    $state.CleanupSafe = $true

    $focusBefore = Get-FmBackendHerdrProjectionFocusSnapshot $session
    if ([string]::IsNullOrEmpty($focusBefore)) {
        Write-FmErr 'error: herdr presentation seeded-tab prune could not capture exact active workspace and tab; refusing a focus-unsafe prune'
        return $state
    }
    if (-not (Remove-FmBackendHerdrSeededDefaultTab -Session $session -WorkspaceId $state.WorkspaceId `
                -SeededTabId $state.SeededTabId -CloseMode 'focus-preserving')) {
        Write-FmErr 'error: herdr presentation seeded-tab prune refused a focus-unsafe close; leaving its journal quarantined'
        return $state
    }
    if (-not (Restore-FmBackendHerdrProjectionFocus -Session $session -Before $focusBefore -Operation 'seeded-tab prune')) {
        Write-FmErr 'error: herdr presentation seeded-tab prune did not preserve exact active focus; leaving its journal quarantined'
        return $state
    }

    $tabs = Invoke-FmBackendHerdrCli -Session $session -Arguments @('tab', 'list', '--workspace', $state.WorkspaceId)
    if (-not $tabs.Ok) {
        Write-FmErr 'error: could not verify the disposable herdr presentation workspace shape'
        return $state
    }
    $panes = Invoke-FmBackendHerdrCli -Session $session -Arguments @('pane', 'list', '--workspace', $state.WorkspaceId)
    if (-not $panes.Ok) {
        Write-FmErr 'error: could not verify the disposable herdr presentation pane shape'
        return $state
    }
    $tabsDoc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut
    $panesDoc = ConvertFrom-FmBackendHerdrJson $panes.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs')) -or
        -not (Test-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))) {
        Write-FmErr 'error: could not parse the disposable herdr presentation workspace shape'
        return $state
    }
    $tabList = @(Get-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))
    $paneList = @(Get-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))
    $seededStillPresent = $false
    foreach ($item in $tabList) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'tab_id') -ceq $state.SeededTabId) { $seededStillPresent = $true }
    }
    if ($tabList.Count -ne 1 -or $paneList.Count -ne 1 -or $seededStillPresent -or
        (Get-FmBackendHerdrItemString -Item $tabList[0] -Key 'tab_id') -cne $state.TabId -or
        (Get-FmBackendHerdrItemString -Item $paneList[0] -Key 'pane_id') -cne $state.PaneId -or
        (Get-FmBackendHerdrItemString -Item $paneList[0] -Key 'tab_id') -cne $state.TabId) {
        Write-FmErr 'error: disposable herdr presentation workspace did not converge to exactly one task pane'
        return $state
    }

    $state.Ok = $true
    return $state
}

<#
.SYNOPSIS
Same-process abort cleanup for a projection whose creates returned exact ids.
.DESCRIPTION
Twin of fm_backend_herdr_projection_cleanup_exact. Performs NO lookup and never
calls `workspace close` - it closes only the exact response-derived panes, and
only through the focus-preserving closer.
#>
function Clear-FmBackendHerdrProjectionExact {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TaskPaneId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$SeededPaneId = ''
    )

    if (-not [string]::IsNullOrEmpty($TaskPaneId)) {
        [void](Close-FmBackendHerdrProjectionPane -Session $Session -PaneId $TaskPaneId)
    }
    if (-not [string]::IsNullOrEmpty($SeededPaneId) -and $SeededPaneId -cne $TaskPaneId) {
        [void](Close-FmBackendHerdrProjectionPane -Session $Session -PaneId $SeededPaneId)
    }
}

<#
.SYNOPSIS
Resolve one exact parent workspace, only when its label is unique in the session.
.DESCRIPTION
Twin of fm_backend_herdr_projection_parent_workspace_exact. A duplicated label is
an unresolvable parent, not a first-match.
#>
function Get-FmBackendHerdrProjectionParentWorkspace {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ParentLabel = ''
    )

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $result.Ok) { return $null }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) { return $null }
    $matched = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'label') -ceq $ParentLabel) {
            $matched += (Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id')
        }
    }
    if ($matched.Count -ne 1 -or [string]::IsNullOrEmpty($matched[0])) { return $null }
    return $matched[0]
}

<#
.SYNOPSIS
Verify one exact projected workspace, its single task tab/pane, its unique token
label, and its position inside the exact parent's contiguous child block.
.DESCRIPTION
Twin of fm_backend_herdr_projection_live_binding_matches. READ-ONLY: this
predicate grants no mutation authority by itself; it is one of several conditions
the reclaim path requires.

The token must appear in EXACTLY ONE workspace label across the whole session
snapshot, and that workspace must be this one - a duplicated token is an ambiguous
binding, never a first-match.
#>
function Test-FmBackendHerdrProjectionLiveBinding {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentWorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskLabel
    )

    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) { return $false }
    $doc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) { return $false }
    $spaces = @(Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))

    $suffix = " $([char]0x00B7) p:$Token"
    $byId = 0
    $byIdAndLabel = 0
    $tokenCount = 0
    $tokenOnTarget = 0
    $parentCount = 0
    $parentIndex = -1
    $childIndex = -1
    for ($i = 0; $i -lt $spaces.Count; $i++) {
        $id = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'workspace_id'
        $label = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'label'
        if ($id -ceq $WorkspaceId) {
            $byId++
            $childIndex = $i
            if ($label -ceq $WorkspaceLabel) { $byIdAndLabel++ }
        }
        if ($label.EndsWith($suffix, $script:FmHerdrOrdinal)) {
            $tokenCount++
            if ($id -ceq $WorkspaceId) { $tokenOnTarget++ }
        }
        if ($id -ceq $ParentWorkspaceId) {
            $parentIndex = $i
            if ($label -ceq $ParentLabel) { $parentCount++ }
        }
    }
    if ($byId -ne 1 -or $byIdAndLabel -ne 1) { return $false }
    if ($tokenCount -ne 1 -or $tokenOnTarget -ne 1) { return $false }
    if ($parentCount -ne 1) { return $false }
    if ($parentIndex -lt 0 -or $childIndex -lt 0 -or $childIndex -le $parentIndex) { return $false }

    for ($i = $parentIndex + 1; $i -lt $childIndex; $i++) {
        $label = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'label'
        $isNew = Test-FmBackendHerdrNewChildLabel $label
        $isLegacyForParent = (Test-FmBackendHerdrLegacyChildLabel $label) -and
        $label.StartsWith("$ParentLabel/", $script:FmHerdrOrdinal)
        if (-not ($isNew -or $isLegacyForParent)) { return $false }
    }

    $tabs = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $WorkspaceId)
    if (-not $tabs.Ok) { return $false }
    $tabsDoc = ConvertFrom-FmBackendHerdrJson $tabs.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))) { return $false }
    $tabList = @(Get-FmBackendHerdrJsonArray -Document $tabsDoc -Path @('result', 'tabs'))
    if ($tabList.Count -ne 1) { return $false }
    if ((Get-FmBackendHerdrItemString -Item $tabList[0] -Key 'tab_id') -cne $TabId) { return $false }
    if ((Get-FmBackendHerdrItemString -Item $tabList[0] -Key 'label') -cne $TaskLabel) { return $false }

    $panes = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $WorkspaceId)
    if (-not $panes.Ok) { return $false }
    $panesDoc = ConvertFrom-FmBackendHerdrJson $panes.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))) { return $false }
    $paneList = @(Get-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))
    if ($paneList.Count -ne 1) { return $false }
    if ((Get-FmBackendHerdrItemString -Item $paneList[0] -Key 'pane_id') -cne $PaneId) { return $false }
    return ((Get-FmBackendHerdrItemString -Item $paneList[0] -Key 'tab_id') -ceq $TabId)
}

<#
.SYNOPSIS
Roll back only the exact response-derived new pane of a failed reclaim.
.DESCRIPTION
Twin of fm_backend_herdr_projection_reclaim_rollback. A pane that is already dead
needs no rollback; a LIVE or UNKNOWN pane refuses rollback entirely, because
closing something that might hold a real agent is worse than leaving an extra
husk. Returns $true only when the pane is confirmed gone.
#>
function Undo-FmBackendHerdrProjectionReclaim {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewPaneId
    )

    switch -CaseSensitive (Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $NewPaneId) {
        'dead' { return $true }
        'no-agent' { }
        default { return $false }
    }
    if ((Close-FmBackendHerdrProjectionPane -Session $Session -PaneId $NewPaneId -RequiredAgentState 'no-agent').Code -ne 0) {
        return $false
    }
    return ((Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $NewPaneId) -ceq 'dead')
}

<#
.SYNOPSIS
Replace one exact agent-free restored projection husk inside its own workspace.
.DESCRIPTION
Twin of fm_backend_herdr_projection_reclaim_task. The caller holds the session
presentation lock and has already established that flat fallback is safe across
every token match.

  Code 0 - exact reclaim; TabId/PaneId hold the replacement endpoint.
  Code 2 - a NON-MUTATING or exactly rolled-back refusal; flat fallback permitted.
  Code 1 - a live/unknown pane or a post-mutation uncertainty that must REFUSE the
           launch, because proceeding could duplicate a live agent.

THE REPLACEMENT IS CREATED AND VERIFIED BEFORE THE OLD PANE IS RECHECKED AND
CLOSED, and the journal advances atomically to the replacement endpoint before
metadata publication. This path never moves, closes, deletes or renames a
workspace and never touches a parent, sibling, captain or foreign pane.
#>
function Restore-FmBackendHerdrProjectionTask {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FmHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaWorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaTabId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaPaneId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkingDirectory
    )

    $refuse = @{ Code = 1; TabId = ''; PaneId = '' }
    $flat = @{ Code = 2; TabId = ''; PaneId = '' }

    $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $Journal -TaskId $TaskId
    if ($null -eq $snapshot) { return $refuse }
    if ($snapshot.Version -cne '2') {
        Write-FmErr "warning: herdr presentation journal for $TaskId has no exact restart binding; spawning flat"
        return $flat
    }
    $canonicalHome = Get-FmBackendHerdrProjectionHomeIdentity $FmHome
    if ([string]::IsNullOrEmpty($canonicalHome)) {
        Write-FmErr "warning: herdr presentation home for $TaskId could not be resolved exactly; spawning flat"
        return $flat
    }
    if ($snapshot.Home -cne $canonicalHome -or $snapshot.Session -cne $Session -or
        $snapshot.WorkspaceId -cne $MetaWorkspaceId -or $snapshot.TabId -cne $MetaTabId -or
        $snapshot.PaneId -cne $MetaPaneId -or $snapshot.ParentLabel -cne $ParentLabel -or
        $snapshot.TaskLabel -cne $TaskLabel) {
        Write-FmErr "warning: herdr presentation binding for $TaskId does not match its exact home, endpoint, or parent; spawning flat"
        return $flat
    }
    if (-not (Test-FmBackendHerdrProjectionLiveBinding -Session $Session -Token $snapshot.ProjectionId `
                -WorkspaceId $MetaWorkspaceId -TabId $MetaTabId -PaneId $MetaPaneId `
                -ParentWorkspaceId $snapshot.ParentWorkspaceId -ParentLabel $ParentLabel `
                -WorkspaceLabel $snapshot.WorkspaceLabel -TaskLabel $TaskLabel)) {
        Write-FmErr "warning: herdr presentation binding for $TaskId has an ambiguous, renamed, foreign, or non-nested live shape; spawning flat"
        return $flat
    }

    $state = Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $MetaPaneId
    if ($state -ceq 'dead') {
        Write-FmErr "warning: exact herdr presentation pane for $TaskId is gone; spawning flat"
        return $flat
    }
    if ($state -cne 'no-agent') {
        Write-FmErr "error: exact herdr presentation pane for $TaskId is $state; refusing duplicate launch"
        return $refuse
    }

    $focusBefore = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ([string]::IsNullOrEmpty($focusBefore)) {
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not capture exact focus; spawning flat"
        return $flat
    }
    $activeTab = $focusBefore.Substring($focusBefore.IndexOf($script:FmHerdrTab) + 1)
    if ($activeTab -ceq $MetaTabId) {
        Write-FmErr "warning: herdr presentation reclaim for $TaskId would replace the active tab; spawning flat"
        return $flat
    }

    $out = Invoke-FmBackendHerdrCli -Session $Session -Arguments @(
        'tab', 'create', '--workspace', $MetaWorkspaceId, '--cwd', $WorkingDirectory,
        '--label', $TaskLabel, '--no-focus')
    if (-not $out.Ok) {
        if (-not (Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $focusBefore -Operation 'husk replacement create')) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not create an exact replacement; spawning flat"
        return $flat
    }
    $doc = ConvertFrom-FmBackendHerdrJson $out.StdOut
    $newTab = Get-FmBackendHerdrJsonString $doc @('result', 'tab', 'tab_id')
    $newPane = Get-FmBackendHerdrJsonString $doc @('result', 'root_pane', 'pane_id')
    if ([string]::IsNullOrEmpty($newTab) -or [string]::IsNullOrEmpty($newPane)) {
        if (-not (Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $focusBefore -Operation 'husk replacement create')) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId returned ambiguous replacement ids; spawning flat"
        return $flat
    }
    if (-not (Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $focusBefore -Operation 'husk replacement create')) { return $refuse }

    $info = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'get', $newTab)
    $infoDoc = if ($info.Ok) { ConvertFrom-FmBackendHerdrJson $info.StdOut } else { $null }
    if ((Get-FmBackendHerdrJsonString $infoDoc @('result', 'tab', 'tab_id')) -cne $newTab -or
        (Get-FmBackendHerdrJsonString $infoDoc @('result', 'tab', 'workspace_id')) -cne $MetaWorkspaceId) {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not verify its replacement tab; spawning flat"
        return $flat
    }
    $info = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'get', $newPane)
    $infoDoc = if ($info.Ok) { ConvertFrom-FmBackendHerdrJson $info.StdOut } else { $null }
    if ((Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'pane_id')) -cne $newPane -or
        (Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'tab_id')) -cne $newTab -or
        (Get-FmBackendHerdrJsonString $infoDoc @('result', 'pane', 'workspace_id')) -cne $MetaWorkspaceId) {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not verify its replacement pane; spawning flat"
        return $flat
    }

    # The replacement pane is prepared BEFORE the old husk is touched - past this
    # point a failure could no longer roll back cleanly.
    if (-not (Initialize-FmBackendHerdrPaneShell -Session $Session -PaneId $newPane)) {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim replacement pane for $TaskId never reached a POSIX shell; spawning flat"
        return $flat
    }

    $state = Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $MetaPaneId
    if ($state -cne 'no-agent') {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        if ($state -ceq 'dead') {
            Write-FmErr "warning: herdr presentation pane for $TaskId disappeared during reclaim; spawning flat"
            return $flat
        }
        Write-FmErr "error: herdr presentation pane for $TaskId became $state during reclaim; refusing duplicate launch"
        return $refuse
    }

    $close = Close-FmBackendHerdrProjectionPane -Session $Session -PaneId $MetaPaneId -RequiredAgentState 'no-agent'
    if ($close.Code -ne 0) {
        if ($close.Code -eq 2) { return $refuse }
        $closeState = $close.AgentState
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        if ($closeState -ceq 'live' -or $closeState -ceq 'unknown') {
            Write-FmErr "error: herdr presentation pane for $TaskId became $closeState at the close boundary; refusing duplicate launch"
            return $refuse
        }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not close the exact old husk; spawning flat"
        return $flat
    }
    if ((Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $MetaPaneId) -cne 'dead') {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        return $refuse
    }
    if (-not (Test-FmBackendHerdrProjectionLiveBinding -Session $Session -Token $snapshot.ProjectionId `
                -WorkspaceId $MetaWorkspaceId -TabId $newTab -PaneId $newPane `
                -ParentWorkspaceId $snapshot.ParentWorkspaceId -ParentLabel $ParentLabel `
                -WorkspaceLabel $snapshot.WorkspaceLabel -TaskLabel $TaskLabel)) {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId did not converge exactly; spawning flat"
        return $flat
    }
    if (-not (Update-FmBackendHerdrProjectionJournalEndpoint -Journal $Journal -TaskId $TaskId `
                -OldTabId $MetaTabId -OldPaneId $MetaPaneId -NewTabId $newTab -NewPaneId $newPane)) {
        if (-not (Undo-FmBackendHerdrProjectionReclaim -Session $Session -NewPaneId $newPane)) { return $refuse }
        Write-FmErr "warning: herdr presentation reclaim for $TaskId could not publish its replacement binding; spawning flat"
        return $flat
    }
    return @{ Code = 0; TabId = $newTab; PaneId = $newPane }
}

<#
.SYNOPSIS
May a task with an existing journal fall back to the flat home workspace?
.DESCRIPTION
Twin of fm_backend_herdr_projection_recovery_allows_flat. Inspects the journal's
exact token matches WITHOUT adopting, reusing, renaming, closing or deleting
anything.

Missing matches safely degrade to the normal flat workspace. One or more matches
allow flat fallback only when EVERY pane is positively dead or agent-free; a LIVE
or UNKNOWN pane refuses a duplicate launch, which is the whole point of the check.
#>
function Test-FmBackendHerdrProjectionFlatFallback {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId
    )

    $token = Get-FmBackendHerdrProjectionJournalToken -Journal $Journal -TaskId $TaskId
    if ([string]::IsNullOrEmpty($token)) {
        Write-FmErr "error: malformed herdr presentation journal for $TaskId; refusing duplicate launch"
        return $false
    }
    if (-not (Initialize-FmBackendHerdrServer $Session)) {
        Write-FmErr "error: could not inspect the quarantined herdr presentation for $TaskId; refusing duplicate launch"
        return $false
    }
    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) {
        Write-FmErr "error: could not list herdr workspaces while inspecting the quarantined presentation for $TaskId"
        return $false
    }
    $doc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        Write-FmErr "error: could not parse herdr workspaces while inspecting the quarantined presentation for $TaskId"
        return $false
    }

    $suffix = " $([char]0x00B7) p:$token"
    $wsids = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        $label = Get-FmBackendHerdrItemString -Item $item -Key 'label'
        if ($label.EndsWith($suffix, $script:FmHerdrOrdinal)) {
            $wsids += (Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id')
        }
    }
    $wsids = @($wsids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($wsids.Count -eq 0) {
        Write-FmErr "warning: no exact herdr presentation token match for $TaskId; leaving any stale space untouched and spawning flat"
        return $true
    }
    if ($wsids.Count -gt 1) {
        Write-FmErr "warning: $($wsids.Count) exact herdr presentation token matches for $TaskId are quarantined; inspecting only for duplicate-agent risk"
    }

    foreach ($wsid in $wsids) {
        $panes = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $wsid)
        if (-not $panes.Ok) {
            Write-FmErr "error: could not inspect herdr presentation workspace $wsid for $TaskId; refusing duplicate launch"
            return $false
        }
        $panesDoc = ConvertFrom-FmBackendHerdrJson $panes.StdOut
        if (-not (Test-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))) {
            Write-FmErr "error: could not parse herdr presentation workspace $wsid for $TaskId; refusing duplicate launch"
            return $false
        }
        foreach ($item in (Get-FmBackendHerdrJsonArray -Document $panesDoc -Path @('result', 'panes'))) {
            $pane = Get-FmBackendHerdrItemString -Item $item -Key 'pane_id'
            if ([string]::IsNullOrEmpty($pane)) { continue }
            $state = Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $pane
            if ($state -cne 'dead' -and $state -cne 'no-agent') {
                Write-FmErr "error: quarantined herdr presentation for $TaskId has a $state pane; refusing duplicate launch"
                return $false
            }
        }
    }
    Write-FmErr "warning: quarantined herdr presentation for $TaskId is dead or agent-free; exact bound reclaim may proceed, otherwise spawning flat"
    return $true
}

<#
.SYNOPSIS
Read-only correlation for retiring a journal after normal exact-pane teardown.
.DESCRIPTION
Twin of fm_backend_herdr_projection_endpoint_matches_journal. EXACTLY ONE
token-bearing workspace must match the endpoint workspace. This verdict never
authorizes a Herdr mutation.
#>
function Test-FmBackendHerdrProjectionEndpointJournal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId
    )

    $token = Get-FmBackendHerdrProjectionJournalToken -Journal $Journal -TaskId $TaskId
    if ([string]::IsNullOrEmpty($token)) { return $false }
    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) { return $false }
    $doc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    if (-not (Test-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) { return $false }

    $suffix = " $([char]0x00B7) p:$token"
    $matched = @()
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('result', 'workspaces'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'label').EndsWith($suffix, $script:FmHerdrOrdinal)) {
            $matched += (Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id')
        }
    }
    return (($matched -join "`n") -ceq $WorkspaceId)
}

<#
.SYNOPSIS
Place a freshly projected workspace after its owning parent's child block.
.DESCRIPTION
Twin of fm_backend_herdr_projection_order_best_effort.

PRESENTATION ONLY, AND ALWAYS SUCCEEDS. Every unavailable, ambiguous, failed or
unverifiable ordering step prints a warning and leaves the safely-created worker
running in Herdr's current order - ordering failure NEVER fails a task spawn. It
never looks up a task endpoint, adopts or reuses a workspace, retries an ambiguous
move, or calls any close/delete/rename primitive. The sole move target is the
workspace id captured from THIS projected create's own response.

-ParentWorkspaceId is that parent's EXACT id when the caller already resolved it
from the launching agent's own herdr identity; it anchors the owning parent by id,
so two workspaces sharing the home label no longer make the whole layout
ambiguous. Omitted, the parent is located by label exactly as before.

After a successful move, every pre-existing workspace id sequence excluding the
new id must be byte-identical to the pre-move sequence.
#>
function Set-FmBackendHerdrProjectionOrder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal best-effort helper whose bash twin acts unconditionally and never fails its caller; a confirmation surface would diverge from the twin.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$CreatedWorkspaceId,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$ParentWorkspaceId = ''
    )

    if ([string]::IsNullOrEmpty($ParentLabel)) {
        Write-FmErr 'warning: herdr presentation ordering missing owning parent label; leaving worker in Herdr''s current order'
        return
    }
    $list = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $list.Ok) {
        Write-FmErr 'warning: herdr presentation ordering could not list workspaces; leaving worker in Herdr''s current order'
        return
    }
    $doc = ConvertFrom-FmBackendHerdrJson $list.StdOut
    $analysis = Get-FmBackendHerdrProjectionOrderAnalysis -Document $doc -CreatedWorkspaceId $CreatedWorkspaceId `
        -ParentLabel $ParentLabel -ParentWorkspaceId $ParentWorkspaceId
    if ($null -eq $analysis) {
        Write-FmErr 'warning: herdr presentation ordering found an ambiguous workspace layout; leaving worker in Herdr''s current order'
        return
    }
    if ($analysis.Current -eq $analysis.Desired) { return }

    switch (Test-FmBackendHerdrWorkspaceMoveCapable $Session) {
        0 { }
        1 {
            Write-FmErr 'warning: herdr presentation ordering requires python3; leaving worker in Herdr''s current order'
            return
        }
        2 {
            Write-FmErr 'warning: herdr presentation ordering could not verify the client protocol; leaving worker in Herdr''s current order'
            return
        }
        3 {
            Write-FmErr "warning: herdr presentation ordering needs protocol $($script:FmHerdrMinWorkspaceMoveProtocol) or newer; leaving worker in Herdr's current order"
            return
        }
        4 {
            Write-FmErr 'warning: herdr presentation ordering could not read the API schema; leaving worker in Herdr''s current order'
            return
        }
        default {
            Write-FmErr 'warning: herdr presentation ordering API support is unavailable or ambiguous; leaving worker in Herdr''s current order'
            return
        }
    }

    $socket = Get-FmBackendHerdrPresentationSessionSocketPath $Session
    if ([string]::IsNullOrEmpty($socket)) {
        Write-FmErr 'warning: herdr presentation ordering found an ambiguous named session socket; leaving worker in Herdr''s current order'
        return
    }
    $focusBefore = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ([string]::IsNullOrEmpty($focusBefore)) {
        Write-FmErr 'warning: herdr presentation ordering could not capture exact active workspace and tab; leaving worker in Herdr''s current order'
        return
    }
    $move = Invoke-FmBackendHerdrWorkspaceMove -Socket $socket -WorkspaceId $CreatedWorkspaceId `
        -InsertIndex ([string]$analysis.Desired)
    [void](Restore-FmBackendHerdrProjectionFocus -Session $Session -Before $focusBefore -Operation 'workspace move')
    if ($move.ExitCode -ne 0) {
        Write-FmErr 'warning: herdr presentation workspace move failed or had an ambiguous response; leaving worker running without cleanup'
        return
    }

    $response = ConvertFrom-FmBackendHerdrJson $move.StdOut
    if ((Get-FmBackendHerdrJsonString $response @('result', 'type')) -cne 'workspace_list' -or
        -not (Test-FmBackendHerdrJsonArray -Document $response -Path @('result', 'workspaces'))) {
        Write-FmErr 'warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup'
        return
    }
    $after = @(Get-FmBackendHerdrJsonArray -Document $response -Path @('result', 'workspaces'))
    $parentIndices = @()
    for ($i = 0; $i -lt $after.Count; $i++) {
        if (Test-FmBackendHerdrIsParentWorkspace -Item $after[$i] -ParentLabel $ParentLabel -ParentWorkspaceId $ParentWorkspaceId) {
            $parentIndices += $i
        }
    }
    if ($analysis.Desired -ge $after.Count -or
        (Get-FmBackendHerdrItemString -Item $after[$analysis.Desired] -Key 'workspace_id') -cne $CreatedWorkspaceId -or
        $parentIndices.Count -ne 1 -or $parentIndices[0] -ge $analysis.Desired) {
        Write-FmErr 'warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup'
        return
    }

    $afterExisting = @()
    foreach ($item in $after) {
        $id = Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id'
        if ($id -cne $CreatedWorkspaceId) { $afterExisting += $id }
    }
    if (($afterExisting -join "`n") -cne (@($analysis.Existing) -join "`n")) {
        Write-FmErr 'warning: herdr presentation workspace move did not preserve relative order; leaving worker running without cleanup'
    }
}

<#
.SYNOPSIS
Is this workspace the owning parent, by exact id when known and by label otherwise?
#>
function Test-FmBackendHerdrIsParentWorkspace {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Item,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ParentWorkspaceId
    )

    if (-not [string]::IsNullOrEmpty($ParentWorkspaceId)) {
        return ((Get-FmBackendHerdrItemString -Item $Item -Key 'workspace_id') -ceq $ParentWorkspaceId)
    }
    return ((Get-FmBackendHerdrItemString -Item $Item -Key 'label') -ceq $ParentLabel)
}

<#
.SYNOPSIS
Where the newly created projection should sit, or $null when the layout is ambiguous.
.DESCRIPTION
The analysis half of Set-FmBackendHerdrProjectionOrder, kept separate because it is
pure - it reads one workspace listing and decides, without touching anything.

Requires the created workspace to be present exactly once AND to be LAST (it was
just created), the owning parent to resolve to exactly one workspace BEFORE it, and
every workspace between the parent's contiguous child block and the created one to
be a well-formed child of a declared owner. Anything else is an ambiguous layout,
and an ambiguous layout is left alone.
#>
function Get-FmBackendHerdrProjectionOrderAnalysis {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Document,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CreatedWorkspaceId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ParentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ParentWorkspaceId
    )

    if (-not (Test-FmBackendHerdrJsonArray -Document $Document -Path @('result', 'workspaces'))) { return $null }
    $spaces = @(Get-FmBackendHerdrJsonArray -Document $Document -Path @('result', 'workspaces'))
    if ($spaces.Count -eq 0) { return $null }

    $createdIndices = @()
    $parentIndices = @()
    for ($i = 0; $i -lt $spaces.Count; $i++) {
        if ((Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'workspace_id') -ceq $CreatedWorkspaceId) {
            $createdIndices += $i
        }
        if (Test-FmBackendHerdrIsParentWorkspace -Item $spaces[$i] -ParentLabel $ParentLabel -ParentWorkspaceId $ParentWorkspaceId) {
            $parentIndices += $i
        }
    }
    if ($createdIndices.Count -ne 1) { return $null }
    $current = $createdIndices[0]
    if ($current -ne ($spaces.Count - 1)) { return $null }
    if ($parentIndices.Count -ne 1) { return $null }
    $pidx = $parentIndices[0]
    if ($pidx -ge $current) { return $null }

    # The parent's existing contiguous child block, counted from the workspace
    # immediately after the parent. New-format children and, for compatibility
    # only, already adjacent legacy children may extend it read-only; they are
    # never renamed or moved.
    $block = 0
    for ($i = $pidx + 1; $i -lt $current; $i++) {
        if ($block -ne ($i - $pidx - 1)) { break }
        $label = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'label'
        $isChild = (Test-FmBackendHerdrNewChildLabel $label) -or
            ((Test-FmBackendHerdrLegacyChildLabel $label) -and $label.StartsWith("$ParentLabel/", $script:FmHerdrOrdinal))
        if (-not $isChild) { break }
        $block++
    }

    # Everything after that block and before the created workspace must be a
    # well-formed parent/child sequence: a foreign, ambiguous, detached or
    # manually interleaved child makes ordering skip rather than rewrite a layout
    # it does not understand.
    $activeParent = $null
    for ($i = $pidx + 1 + $block; $i -lt $current; $i++) {
        $label = Get-FmBackendHerdrItemString -Item $spaces[$i] -Key 'label'
        if (Test-FmBackendHerdrTopLevelParentLabel $label) {
            $activeParent = $label
        } elseif (Test-FmBackendHerdrNewChildLabel $label) {
            if ($null -eq $activeParent) { return $null }
        } elseif (Test-FmBackendHerdrLegacyChildLabel $label) {
            if ($null -eq $activeParent) { return $null }
            if (-not $label.StartsWith("$activeParent/", $script:FmHerdrOrdinal)) { return $null }
        } else {
            $activeParent = $null
        }
    }

    $existing = @()
    foreach ($item in $spaces) {
        $id = Get-FmBackendHerdrItemString -Item $item -Key 'workspace_id'
        if ($id -cne $CreatedWorkspaceId) { $existing += $id }
    }
    return @{
        Current     = $current
        Desired     = $pidx + 1 + $block
        ParentIndex = $pidx
        Existing    = [string[]]$existing
    }
}

# --- native event push: the pane.agent_status_changed subscriber ---------------
#
# The push half of the immediate blocked-state escalation. Instead of a blind
# sleep, Wait-FmBackendHerdrTransition blocks on herdr's native event stream and
# returns the instant a subscribed pane transitions to `blocked`, so a crew
# waiting on the human wakes its supervisor sub-second instead of after the ~240s
# stale-pane wedge timer. Everything not `blocked` is streamed too (the POLICY,
# not the subscription, makes `blocked` the sole immediate action) so `working`
# edges clear the per-pane dedupe marker.
#
# POLLING REMAINS THE PERMANENT BACKSTOP. Below-capability, a connect or subscribe
# failure, or an unusable reader all fall back to the caller sleeping the same
# budget - which is what the return-code trichotomy below encodes.
#
# WHAT REPLACED herdr-eventwait.py, AND WHY IT IS SAFE (inventory R5: contract the
# OUTPUT, not the mechanism). The bash twin builds a temp dir, mkfifos, starts a
# Python AF_UNIX subscriber writing into the fifo, opens fd 9 on it, line-reads,
# closes the fd and rm -rf's the dir. None of that exists here: .NET reaches the
# same newline-delimited JSON directly, so there is no fifo, no fd table, no
# background process and no python3 dependency on this path. What IS contracted,
# and what the differential suite asserts, is identical: the same normalized
# transition records, the same 0/1/2 return trichotomy, and the same timeout
# behavior at the boundary.
#
# THE TRANSPORT, VERIFIED LIVE ON THIS HOST against herdr 0.7.5-preview in an
# isolated fm-lab session:
#   * On Windows the herdr.sock PATH is a MARKER FILE holding "pid:starttime" for
#     staleness detection; the real listener is a NAMED PIPE whose name is the
#     pipe namespace plus that sock file's full Windows path. Confirmed by listing
#     \\.\pipe\ (the entry is present) and by a live subscribe answered over it
#     with {"result":{"type":"subscription_started"}}.
#   * Off Windows it is an ordinary AF_UNIX stream socket, reached through
#     UnixDomainSocketEndPoint. Same JSON either way; only the byte transport
#     differs.
#
# THE ORDERING CONSTRAINT, FOUND THE HARD WAY AND PRESERVED HERE: a pending
# synchronous read BLOCKS writes on the same pipe handle, so the subscribe request
# is WRITTEN BEFORE ANY READ IS STARTED. The Python reader solves the same problem
# by starting its pump thread lazily on first recv; this solves it by simply
# writing first, which is both simpler and impossible to get subtly wrong later.

<#
.SYNOPSIS
The control-socket path for a session, as `herdr session list --json` reports it.
.DESCRIPTION
Twin of fm_backend_herdr_socket_path. Deliberately NOT canonicalized and NOT
session-flagged: the bash twin reads the raw field with a bare `herdr` call, and
this value is handed to the reader as a transport address rather than compared as
an identity (Get-FmBackendHerdrCanonicalSocketPath owns the identity comparisons).
Verified: the default session's socket differs from a named session's.
#>
function Get-FmBackendHerdrSocketPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return '' }
    $result = Invoke-FmTool -FilePath $herdr.Source -Arguments @('session', 'list', '--json')
    if (-not $result.Ok) { return '' }
    $doc = ConvertFrom-FmBackendHerdrJson $result.StdOut
    foreach ($item in (Get-FmBackendHerdrJsonArray -Document $doc -Path @('sessions'))) {
        if ((Get-FmBackendHerdrItemString -Item $item -Key 'name') -ceq $Session) {
            $socket = Get-FmBackendHerdrItemString -Item $item -Key 'socket_path'
            if (-not [string]::IsNullOrEmpty($socket)) { return $socket }
        }
    }
    return ''
}

<#
.SYNOPSIS
Is this session's push path usable right now?
.DESCRIPTION
Twin of fm_backend_herdr_events_capable, the version/capability gate that fails
closed to the poll loop. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict
for tests (1 = capable, 0 = incapable) without touching the real binary. The
`api schema` read is ~220KB, so callers memoize this per session for a process
lifetime rather than probing every poll.

ONE GATE IS DELIBERATELY ABSENT. The bash twin requires python3 when no reader
override is configured, because with no override its reader IS
herdr-eventwait.py. Here, no override means the NATIVE reader, which needs no
interpreter at all - so carrying that requirement would refuse the push path on a
host where it demonstrably works, for a dependency this path does not have. With
an override configured, neither world checks anything, exactly as before. (On the
differential oracle host python3 IS installed - herdr's presentation ordering
needs it - so the two worlds answer identically there regardless.)
#>
function Test-FmBackendHerdrEventsCapable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Session',
        Justification = 'Declared and unused, faithfully: the bash twin also takes a session argument and also never uses it, because every probe here is a session-INDEPENDENT client read (bare `herdr status --json` and `herdr api schema --json`). The dispatcher passes a session through, so the parameter must exist; using it would change which server is queried and therefore what the capability verdict means.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')

    switch (Get-FmEnv -Name 'FM_BACKEND_HERDR_EVENTS_FORCE') {
        '1' { return $true }
        '0' { return $false }
        default { }
    }
    if (-not (Test-FmBackendHerdrTool)) { return $false }

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return $false }
    $status = Invoke-FmTool -FilePath $herdr.Source -Arguments @('status', '--json')
    $protocol = Get-FmBackendHerdrJsonString (ConvertFrom-FmBackendHerdrJson $status.StdOut) @('client', 'protocol')
    $value = 0
    if ([string]::IsNullOrEmpty($protocol) -or
        -not [int]::TryParse($protocol, [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $false
    }
    if ($value -lt $script:FmHerdrMinEventsProtocol) { return $false }

    $schema = Invoke-FmTool -FilePath $herdr.Source -Arguments @('api', 'schema', '--json')
    if (-not $schema.Ok) { return $false }
    # `grep -Fq` twins: a fixed-string presence test over the raw schema text.
    if (-not $schema.StdOut.Contains('events.subscribe')) { return $false }
    return $schema.StdOut.Contains('pane.agent_status_changed')
}

<#
.SYNOPSIS
Normalize one herdr edge into the shared, backend-neutral transition record.
.DESCRIPTION
Twin of fm_backend_herdr_normalize_event, and THE single normalize point: both the
stream reader's projected lines AND the level-reconcile's `agent get` reads flow
through here into bin/fm-transition-lib.psm1's record shape. herdr's event carries
no previous status and its stream is edge-triggered, so from_status is left empty;
to_status drives the policy.
#>
function ConvertTo-FmBackendHerdrEventRecord {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$PaneId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Status = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Agent = ''
    )
    return (New-FmTransitionRecord $PaneId $WorkspaceId '' $Status $Agent)
}

<#
.SYNOPSIS
The external reader argv, or @() when the native transport should be used.
.DESCRIPTION
Twin of fm_backend_herdr_event_reader_cmd, with one deliberate change of DEFAULT.
The bash twin defaults to `python3 <dir>/herdr-eventwait.py`; here the default is
the native transport, so this returns an empty array and Wait-FmBackendHerdrTransition
speaks the protocol itself.

FM_BACKEND_HERDR_EVENT_READER is still honored, still whitespace-split, and still
receives the identical argv (`<sock> <timeout> <pane-id>...`) with the identical
stdout contract (`@subscribed`, then TAB-separated projections; exit 0 = clean
budget, non-zero = fall back to polling). That is the seam the event suites replay
canned streams through, and losing it would have cost more coverage than the
native transport gains.
#>
function Get-FmBackendHerdrEventReaderCommand {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $override = Get-FmEnv -Name 'FM_BACKEND_HERDR_EVENT_READER'
    if ([string]::IsNullOrEmpty($override)) { return [string[]]@() }
    return [string[]]@($override.Split([char[]]@(' ', "`t", "`n", "`r"), [System.StringSplitOptions]::RemoveEmptyEntries))
}

<#
.SYNOPSIS
The per-pane escalation dedupe marker path for a window.
.DESCRIPTION
Twin of fm_backend_herdr_escalation_marker, keyed identically to the watcher's own
.stale-<key> (`tr ':/.' '___'`), so the two naming schemes cannot drift.
#>
function Get-FmBackendHerdrEscalationMarker {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Window
    )

    $key = $Window -replace '[:/.]', '_'
    return "$StateDir/$($script:FmHerdrEscalatedPrefix)$key"
}

<#
.SYNOPSIS
Route one normalized record through the shared policy, maintaining the dedupe marker.
.DESCRIPTION
Twin of fm_backend_herdr_apply_transition. On a FRESH actionable (blocked) edge -
policy actionable AND no marker yet - it returns the record and the caller stops
and hands it up; the caller commits the marker only AFTER handling the record, so
a crash between the two re-delivers rather than swallows. `absorb` (working) clears
the marker. `defer`/`fallback`, and an already-marked `actionable`, return $null
with no side effect.
#>
function Select-FmBackendHerdrTransition {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Record
    )

    $paneId = Get-FmTransitionPaneId $Record
    if ([string]::IsNullOrEmpty($paneId)) { return $null }
    $action = Get-FmTransitionPolicy (Get-FmTransitionToStatus $Record)
    $window = "$Session`:$paneId"
    $marker = ConvertTo-FmNativePath (Get-FmBackendHerdrEscalationMarker -StateDir $StateDir -Window $window)

    if ($action -ceq 'actionable') {
        if (-not [System.IO.File]::Exists($marker) -and -not [System.IO.Directory]::Exists($marker)) {
            return $Record
        }
    } elseif ($action -ceq 'absorb') {
        try { if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) } } catch { $null = $_ }
    }
    return $null
}

<#
.SYNOPSIS
Commit a normalized transition record as the backend's new known state.
.DESCRIPTION
Twin of fm_backend_herdr_commit_transition: the `: > "$marker"` that makes the
escalation one-shot per blocked edge.
#>
function Save-FmBackendHerdrTransition {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Record
    )

    $paneId = Get-FmTransitionPaneId $Record
    if ([string]::IsNullOrEmpty($paneId)) { return $false }
    $marker = ConvertTo-FmNativePath (Get-FmBackendHerdrEscalationMarker -StateDir $StateDir -Window "$Session`:$paneId")
    try {
        [System.IO.File]::WriteAllBytes($marker, [byte[]]@())
    } catch {
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Clear a window's recorded transition state.
.DESCRIPTION
Twin of fm_backend_herdr_clear_transition. An empty window is a no-op success, and
a missing marker is success too - `rm -f` never fails on an absent file.
#>
function Clear-FmBackendHerdrTransition {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Window = ''
    )

    if ([string]::IsNullOrEmpty($Window)) { return $true }
    $marker = ConvertTo-FmNativePath (Get-FmBackendHerdrEscalationMarker -StateDir $StateDir -Window $Window)
    try { if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) } } catch { $null = $_ }
    return $true
}

<#
.SYNOPSIS
Read one TAB field the way `cut -f N` reads it, including cut's own quirk.
.DESCRIPTION
The stream projection is split with `cut`, NOT `IFS=$'\t' read`, and the bash twin
comments on exactly why: a TAB is IFS-whitespace, so `read` would COLLAPSE an
empty middle field (an absent workspace_id) and shift the status into the wrong
column. cut preserves empty fields - and also prints a line containing NO
delimiter in its entirety for any field number, which is reproduced here so a
malformed single-field line behaves identically in both worlds.
#>
function Get-FmBackendHerdrCutField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '',
        [Parameter(Mandatory, Position = 1)][int]$Field
    )

    if ($null -eq $Line) { return '' }
    if (-not $Line.Contains("`t")) { return $Line }
    $fields = @($Line.Split("`t"))
    if ($Field -lt 1 -or $Field -gt $fields.Count) { return '' }
    return $fields[$Field - 1]
}

<#
.SYNOPSIS
Level-reconcile every subscribed pane once, after subscribing and before draining.
.DESCRIPTION
The reconcile half of Wait-FmBackendHerdrTransition. A pane already `blocked`
during the gap since the last subscription is returned NOW, once, while newer
edges accumulate in the already-live stream - which is the whole reason the
subscribe happens first. `working` panes clear their marker here too.

Returns the record on a fresh actionable edge, or $null.
#>
function Select-FmBackendHerdrLevelTransition {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Window
    )

    foreach ($w in @($Window)) {
        $colon = $w.IndexOf(':')
        if ($colon -lt 0) { continue }
        $paneId = $w.Substring($colon + 1)
        if ([string]::IsNullOrEmpty($paneId)) { continue }
        $raw = Get-FmBackendHerdrAgentStatusRaw -Session $Session -PaneId $paneId
        if ([string]::IsNullOrEmpty($raw)) { continue }
        $record = ConvertTo-FmBackendHerdrEventRecord $paneId '' $raw ''
        $hit = Select-FmBackendHerdrTransition -StateDir $StateDir -Session $Session -Record $record
        if (-not [string]::IsNullOrEmpty($hit)) { return $hit }
    }
    return $null
}

<#
.SYNOPSIS
Derive the herdr named-pipe name from a socket path.
.DESCRIPTION
The Windows transport half. Accepts the MSYS form (/c/Users/...) as well as the
native form (C:\Users\... or C:/Users/...), because the socket path can reach here
from either world's records. Returns the pipe name WITHOUT the `\\.\pipe\` prefix,
which is what NamedPipeClientStream takes alongside a "." server.
#>
function Get-FmBackendHerdrPipeName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$SocketPath = '')

    if ([string]::IsNullOrEmpty($SocketPath)) { return '' }
    $path = $SocketPath
    if ($path.Length -gt 2 -and $path[0] -eq '/' -and $path[2] -eq '/' -and [char]::IsLetter($path[1])) {
        $path = [string]::Concat([char]::ToUpperInvariant($path[1]), ':', $path.Substring(2))
    }
    return ($path -replace '/', '\')
}

<#
.SYNOPSIS
Open the herdr control stream for a session socket.
.DESCRIPTION
Named pipe on Windows, AF_UNIX stream socket elsewhere - same newline-delimited
JSON, no extra authentication either way. Returns a reader hashtable, or $null
when the connection failed (which the caller turns into the poll-loop fallback).

Only the Windows arm is verified on the reference host; the AF_UNIX arm exists so
a pwsh on macOS or Linux is not silently pushed onto the poll path, and the bash
tree remains the authority there.
#>
function Connect-FmBackendHerdrEventStream {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string]$SocketPath)

    try {
        if (Test-FmWindows) {
            $pipeName = Get-FmBackendHerdrPipeName $SocketPath
            if ([string]::IsNullOrEmpty($pipeName)) { return $null }
            $client = [System.IO.Pipes.NamedPipeClientStream]::new(
                '.', $pipeName,
                [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::Asynchronous)
            $client.Connect(5000)
            return @{ Stream = $client; Socket = $null; Pending = [System.Collections.Generic.List[byte]]::new() }
        }
        $endpoint = [System.Net.Sockets.UnixDomainSocketEndPoint]::new((ConvertTo-FmNativePath $SocketPath))
        $socket = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::Unix,
            [System.Net.Sockets.SocketType]::Stream,
            [System.Net.Sockets.ProtocolType]::Unspecified)
        $socket.Connect($endpoint)
        $stream = [System.Net.Sockets.NetworkStream]::new($socket, $true)
        return @{ Stream = $stream; Socket = $socket; Pending = [System.Collections.Generic.List[byte]]::new() }
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
Read one newline-terminated line from the event stream, honoring a deadline.
.DESCRIPTION
The `_read_line` twin: returns @{ Outcome; Line } where Outcome is line, timeout,
closed or error. The bounded wait is ReadAsync plus a CancellationTokenSource, so
the whole wait is in-process with no polling and no helper thread.
#>
function Read-FmBackendHerdrEventLine {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Reader,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    $buffer = [byte[]]::new(65536)
    while ($true) {
        $index = $Reader.Pending.IndexOf([byte]10)
        if ($index -ge 0) {
            $line = ''
            if ($index -gt 0) {
                $line = [System.Text.Encoding]::UTF8.GetString($Reader.Pending.GetRange(0, $index).ToArray())
            }
            $Reader.Pending.RemoveRange(0, $index + 1)
            return @{ Outcome = 'line'; Line = $line }
        }
        $remaining = $Deadline - [DateTime]::UtcNow
        if ($remaining.TotalMilliseconds -le 0) { return @{ Outcome = 'timeout'; Line = '' } }

        $cts = [System.Threading.CancellationTokenSource]::new()
        try {
            $cts.CancelAfter([int][Math]::Min($remaining.TotalMilliseconds, [int]::MaxValue))
            $read = $Reader.Stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token)
            $count = $read.GetAwaiter().GetResult()
            if ($count -le 0) { return @{ Outcome = 'closed'; Line = '' } }
            $Reader.Pending.AddRange($buffer[0..($count - 1)])
        } catch [System.OperationCanceledException] {
            return @{ Outcome = 'timeout'; Line = '' }
        } catch {
            # A cancelled ReadAsync can also surface wrapped; a genuinely broken
            # stream must not be reported as a clean timeout, so the deadline
            # decides which of the two this was.
            if ([DateTime]::UtcNow -ge $Deadline) { return @{ Outcome = 'timeout'; Line = '' } }
            return @{ Outcome = 'error'; Line = '' }
        } finally {
            $cts.Dispose()
        }
    }
}

<#
.SYNOPSIS
Close an event stream, best-effort.
#>
function Disconnect-FmBackendHerdrEventStream {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowNull()][hashtable]$Reader)

    if ($null -eq $Reader) { return }
    try { if ($null -ne $Reader.Stream) { $Reader.Stream.Dispose() } } catch { $null = $_ }
    try { if ($null -ne $Reader.Socket) { $Reader.Socket.Dispose() } } catch { $null = $_ }
}

<#
.SYNOPSIS
Bounded wait for a fresh actionable transition on one of several panes.
.DESCRIPTION
Twin of fm_backend_herdr_wait_transition. Returns @{ Code; Record } where Code is
the exit-status trichotomy every caller branches on, and which IS the contract
(inventory R5):

  0  a fresh actionable (blocked) edge; Record holds the normalized transition.
  1  a CLEAN TIMEOUT - the reader ran the full budget with no fresh actionable
     edge, so the caller has effectively already slept and just continues.
  2  the event path is UNUSABLE - not capable, socket unresolved, connect or
     subscribe failed, or the stream ended early. The caller sleeps the budget
     itself, which is the permanent poll-loop backstop.

ORDER IS PART OF THE CONTRACT: subscribe FIRST, then reconcile current levels,
then drain. Edges occurring during reconciliation are already buffered in the live
stream, so nothing that happens mid-reconcile is lost.
#>
function Wait-FmBackendHerdrTransition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TimeoutSeconds = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 3)][AllowNull()][AllowEmptyCollection()][string[]]$Window = @()
    )

    $fallback = @{ Code = 2; Record = '' }
    $windows = @($Window)
    if ($windows.Count -eq 0) { return $fallback }
    if ((Get-FmEnv -Name 'FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED' -Default '0') -ne '1') {
        if (-not (Test-FmBackendHerdrEventsCapable $Session)) { return $fallback }
    }
    $socket = Get-FmBackendHerdrSocketPath $Session
    if ([string]::IsNullOrEmpty($socket)) { return $fallback }

    # Map each window to its herdr pane id (strip the leading "<session>:").
    $paneIds = @()
    foreach ($w in $windows) {
        $colon = $w.IndexOf(':')
        if ($colon -lt 0) { continue }
        $paneId = $w.Substring($colon + 1)
        if (-not [string]::IsNullOrEmpty($paneId)) { $paneIds += $paneId }
    }
    if ($paneIds.Count -eq 0) { return $fallback }

    $reader = @(Get-FmBackendHerdrEventReaderCommand)
    if ($reader.Count -gt 0) {
        return (Wait-FmBackendHerdrTransitionExternal -Reader $reader -Session $Session `
                -TimeoutSeconds $TimeoutSeconds -StateDir $StateDir -Window $windows `
                -PaneId $paneIds -SocketPath $socket)
    }
    return (Wait-FmBackendHerdrTransitionNative -Session $Session -TimeoutSeconds $TimeoutSeconds `
            -StateDir $StateDir -Window $windows -PaneId $paneIds -SocketPath $socket)
}

<#
.SYNOPSIS
The native transport arm of Wait-FmBackendHerdrTransition.
.DESCRIPTION
Speaks the wire protocol directly:

  request : {"id","method":"events.subscribe","params":{"subscriptions":[
             {"type":"pane.agent_status_changed","pane_id":P}, ...]}}\n
  ack     : {"id",...,"result":{"type":"subscription_started"}}\n
  stream  : {"event":"pane.agent_status_changed",
             "data":{"pane_id","workspace_id","agent_status","agent",...}}\n

THE SUBSCRIBE IS WRITTEN BEFORE ANY READ IS STARTED - see the section header for
why that ordering is load-bearing rather than stylistic.

Every failure mode maps onto the bash twin's observable outcome: a bad timeout, a
failed connect, a failed send and a missing or wrong ack all leave the bash reader
printing no `@subscribed` line, which the bash caller reads as Code 2; a stream
that ends early is the reader's exit 4, also Code 2; running the full budget is
its exit 0, i.e. Code 1.
#>
function Wait-FmBackendHerdrTransitionNative {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TimeoutSeconds,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory)][string[]]$Window,
        [Parameter(Mandatory)][string[]]$PaneId,
        [Parameter(Mandatory)][string]$SocketPath
    )

    $fallback = @{ Code = 2; Record = '' }
    $timeout = 0.0
    if (-not [double]::TryParse($TimeoutSeconds, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$timeout)) {
        return $fallback
    }
    if ($timeout -le 0) { return $fallback }

    $start = [DateTime]::UtcNow
    $deadline = $start.AddSeconds($timeout)
    $reader = Connect-FmBackendHerdrEventStream $SocketPath
    if ($null -eq $reader) { return $fallback }

    try {
        $subscriptions = @()
        foreach ($pane in $PaneId) {
            $subscriptions += @{ type = 'pane.agent_status_changed'; pane_id = $pane }
        }
        $request = @{
            id     = 'fm-eventwait'
            method = 'events.subscribe'
            params = @{ subscriptions = $subscriptions }
        } | ConvertTo-Json -Depth 20 -Compress

        # WRITE BEFORE READ. A pending synchronous read blocks writes on the same
        # pipe handle, so starting a reader first deadlocks the conversation.
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($request + "`n")
            $reader.Stream.Write($bytes, 0, $bytes.Length)
            $reader.Stream.Flush()
        } catch {
            return $fallback
        }

        # The ack gets its own short budget but never runs past the overall one.
        $ackDeadline = $start.AddSeconds(5)
        if ($ackDeadline -gt $deadline) { $ackDeadline = $deadline }
        $ack = Read-FmBackendHerdrEventLine -Reader $reader -Deadline $ackDeadline
        if ($ack.Outcome -cne 'line') { return $fallback }
        $ackDoc = ConvertFrom-FmBackendHerdrJson $ack.Line
        if ((Get-FmBackendHerdrJsonString $ackDoc @('result', 'type')) -cne 'subscription_started') {
            return $fallback
        }

        $hit = Select-FmBackendHerdrLevelTransition -Session $Session -StateDir $StateDir -Window $Window
        if (-not [string]::IsNullOrEmpty($hit)) { return @{ Code = 0; Record = $hit } }

        while ($true) {
            $next = Read-FmBackendHerdrEventLine -Reader $reader -Deadline $deadline
            if ($next.Outcome -ceq 'timeout') { return @{ Code = 1; Record = '' } }
            if ($next.Outcome -cne 'line') { return $fallback }
            if ([string]::IsNullOrEmpty($next.Line)) { continue }
            $message = ConvertFrom-FmBackendHerdrJson $next.Line
            if ($null -eq $message) { continue }
            if ((Get-FmBackendHerdrJsonString $message @('event')) -cne 'pane.agent_status_changed') { continue }
            $paneField = Get-FmBackendHerdrEventField -Document $message -Key 'pane_id'
            if ([string]::IsNullOrEmpty($paneField)) { continue }
            $record = ConvertTo-FmBackendHerdrEventRecord $paneField `
                (Get-FmBackendHerdrEventField -Document $message -Key 'workspace_id') `
                (Get-FmBackendHerdrEventField -Document $message -Key 'agent_status') `
                (Get-FmBackendHerdrEventField -Document $message -Key 'agent')
            $hit = Select-FmBackendHerdrTransition -StateDir $StateDir -Session $Session -Record $record
            if (-not [string]::IsNullOrEmpty($hit)) { return @{ Code = 0; Record = $hit } }
        }
    } finally {
        Disconnect-FmBackendHerdrEventStream $reader
    }
}

<#
.SYNOPSIS
One event data field, cleaned exactly as the Python projection cleaned it.
.DESCRIPTION
herdr-eventwait.py replaced TAB, CR and LF with spaces before writing its
TAB-separated projection, because those bytes would otherwise corrupt the record
the bash side splits with `cut`. The native path builds the same normalized
record, so it applies the same cleaning at the same point rather than trusting the
server never to emit one.
#>
function Get-FmBackendHerdrEventField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Document,
        [Parameter(Mandatory)][string]$Key
    )

    $value = Get-FmBackendHerdrJsonString $Document @('data', $Key)
    if ([string]::IsNullOrEmpty($value)) { return '' }
    return ($value -replace "[`t`r`n]", ' ')
}

<#
.SYNOPSIS
The external-reader arm of Wait-FmBackendHerdrTransition.
.DESCRIPTION
Preserves the FM_BACKEND_HERDR_EVENT_READER seam byte-for-byte: the reader gets
`<sock> <timeout> <pane-id>...`, must print `@subscribed` first, then one
TAB-separated projection per event, and its EXIT CODE decides the difference
between a clean full-budget wait (0 -> Code 1) and a reader error (non-zero ->
Code 2), exactly as the bash twin's `wait "$reader_pid"` does.

The fifo is gone - stdout is read directly - but nothing observable about the
reader contract changed, which is what the differential asserts.
#>
function Wait-FmBackendHerdrTransitionExternal {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$Reader,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TimeoutSeconds,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory)][string[]]$Window,
        [Parameter(Mandatory)][string[]]$PaneId,
        [Parameter(Mandatory)][string]$SocketPath
    )

    $fallback = @{ Code = 2; Record = '' }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Reader[0]
    for ($i = 1; $i -lt $Reader.Count; $i++) { [void]$psi.ArgumentList.Add($Reader[$i]) }
    [void]$psi.ArgumentList.Add($SocketPath)
    [void]$psi.ArgumentList.Add($TimeoutSeconds)
    foreach ($pane in $PaneId) { [void]$psi.ArgumentList.Add($pane) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        try {
            [void]$proc.Start()
        } catch {
            return $fallback
        }
        # stderr is drained concurrently so a chatty reader cannot fill its pipe
        # and block; the bash twin discards it with 2>/dev/null.
        $errTask = $proc.StandardError.ReadToEndAsync()

        $ack = $proc.StandardOutput.ReadLine()
        if ($null -eq $ack -or $ack.TrimEnd("`r") -cne '@subscribed') {
            try { $proc.Kill($true) } catch { $null = $_ }
            $proc.WaitForExit()
            [void]$errTask.GetAwaiter().GetResult()
            return $fallback
        }

        $hit = Select-FmBackendHerdrLevelTransition -Session $Session -StateDir $StateDir -Window $Window
        if (-not [string]::IsNullOrEmpty($hit)) {
            try { $proc.Kill($true) } catch { $null = $_ }
            $proc.WaitForExit()
            [void]$errTask.GetAwaiter().GetResult()
            return @{ Code = 0; Record = $hit }
        }

        while ($true) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -eq $line) { break }
            $line = $line.TrimEnd("`r")
            if ([string]::IsNullOrEmpty($line)) { continue }
            $paneField = Get-FmBackendHerdrCutField -Line $line -Field 1
            if ([string]::IsNullOrEmpty($paneField)) { continue }
            $record = ConvertTo-FmBackendHerdrEventRecord $paneField `
                (Get-FmBackendHerdrCutField -Line $line -Field 2) `
                (Get-FmBackendHerdrCutField -Line $line -Field 3) `
                (Get-FmBackendHerdrCutField -Line $line -Field 4)
            $hit = Select-FmBackendHerdrTransition -StateDir $StateDir -Session $Session -Record $record
            if (-not [string]::IsNullOrEmpty($hit)) {
                try { $proc.Kill($true) } catch { $null = $_ }
                $proc.WaitForExit()
                [void]$errTask.GetAwaiter().GetResult()
                return @{ Code = 0; Record = $hit }
            }
        }

        $proc.WaitForExit()
        [void]$errTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -eq 0) { return @{ Code = 1; Record = '' } }
        return $fallback
    } finally {
        $proc.Dispose()
    }
}

Export-ModuleMember -Function @(
    # CLI, tooling, session, targets
    'Invoke-FmBackendHerdrCli', 'Get-FmBackendHerdrCombinedOutput',
    'Test-FmBackendHerdrTool', 'Test-FmBackendHerdrVersion',
    'Get-FmBackendHerdrSession', 'Get-FmBackendHerdrWorkspaceLabel',
    'Initialize-FmBackendHerdrServer', 'Get-FmBackendHerdrServerRunning',
    'Get-FmBackendHerdrTarget', 'Test-FmBackendHerdrTargetReady',
    'ConvertTo-FmBackendHerdrHostPath', 'ConvertTo-FmBackendHerdrKey',
    # JSON helpers, exported so the differential suite can drive them directly
    'ConvertFrom-FmBackendHerdrJson', 'Get-FmBackendHerdrJsonValue',
    'Get-FmBackendHerdrJsonString', 'Get-FmBackendHerdrJsonArray',
    'Test-FmBackendHerdrJsonArray', 'Get-FmBackendHerdrJsonNumber',
    'Get-FmBackendHerdrItemString', 'Test-FmBackendHerdrItemTrue',
    'Get-FmBackendHerdrCutField', 'Get-FmBackendHerdrIfsPair',
    'Get-FmBackendHerdrTailLine', 'Get-FmBackendHerdrCaptured',
    'Get-FmBackendHerdrCaptureBound', 'Get-FmBackendHerdrCaptureLine',
    'Get-FmBackendHerdrTrimmed', 'Get-FmBackendHerdrShellLeaf',
    'ConvertTo-FmBackendHerdrAwkNumber', 'Get-FmBackendHerdrPhysicalDirectory',
    'Start-FmBackendHerdrSleep', 'Get-FmBackendHerdrIntKnob',
    'Test-FmBackendHerdrScriptedCli',
    # presentation journal
    'New-FmBackendHerdrProjectionId', 'Get-FmBackendHerdrProjectionJournalPath',
    'New-FmBackendHerdrProjectionJournal', 'Get-FmBackendHerdrProjectionJournalField',
    'Get-FmBackendHerdrProjectionJournalSnapshot', 'Get-FmBackendHerdrProjectionJournalToken',
    'Write-FmBackendHerdrProjectionJournalV2', 'Set-FmBackendHerdrProjectionJournalBinding',
    'Update-FmBackendHerdrProjectionJournalEndpoint', 'Get-FmBackendHerdrProjectionHomeIdentity',
    'Get-FmBackendHerdrProjectionConciseTaskLabel', 'Get-FmBackendHerdrProjectionWorkspaceLabel',
    # session presentation lock
    'Get-FmBackendHerdrPresentationLockNamespace', 'Get-FmBackendHerdrPresentationLockNamespaceMode',
    'Get-FmBackendHerdrPresentationLockNamespaceUid', 'Test-FmBackendHerdrPresentationLockNamespace',
    'Get-FmBackendHerdrCanonicalSocketPath', 'Get-FmBackendHerdrPresentationSessionSocketPath',
    'Get-FmBackendHerdrPresentationSessionLockPath', 'Get-FmBackendHerdrSessionLockKey',
    'Get-FmBackendHerdrCurrentUid',
    # focus, close plans, removal
    'Get-FmBackendHerdrProjectionFocusSnapshot', 'Restore-FmBackendHerdrProjectionFocus',
    'Close-FmBackendHerdrProjectionPane', 'Test-FmBackendHerdrWorkspaceMoveCapable',
    'Invoke-FmBackendHerdrWorkspaceMove', 'Test-FmBackendHerdrMoveResponse',
    'Get-FmBackendHerdrEmptyingClosePlan', 'Restore-FmBackendHerdrEmptyingMove',
    'Close-FmBackendHerdrPaneByDeath', 'Close-FmBackendHerdrPaneExplicit',
    'Test-FmBackendHerdrBareShellPid', 'Get-FmBackendHerdrPaneIdleShellPid',
    'Get-FmBackendHerdrPaneIdleShellSample',
    # containers and tasks
    'Get-FmBackendHerdrWorkspaceMatch', 'Get-FmBackendHerdrWorkspace',
    'Get-FmBackendHerdrLauncherIdentity', 'Remove-FmBackendHerdrSeededDefaultTab',
    'Initialize-FmBackendHerdrWorkspace', 'Initialize-FmBackendHerdrContainer',
    'New-FmBackendHerdrTask', 'Get-FmBackendHerdrPaneForTab',
    'Resolve-FmBackendHerdrBareSelector', 'Get-FmBackendHerdrLiveTask',
    'Initialize-FmBackendHerdrPaneShell', 'Test-FmBackendHerdrPaneShellIsPowerShell',
    # presence, agents, husks
    'Get-FmBackendHerdrPanePresenceState', 'Get-FmBackendHerdrWorkspacePresenceState',
    'Get-FmBackendHerdrPaneAgentState', 'Test-FmBackendHerdrTabIsHusk',
    'Get-FmBackendHerdrAgentState', 'Get-FmBackendHerdrAgentAlive',
    'Get-FmBackendHerdrAgentStatusRaw', 'Get-FmBackendHerdrAgentIdentityRaw',
    'Get-FmBackendHerdrAgentStatusClass', 'Get-FmBackendHerdrSubmitStatusClass',
    'Get-FmBackendHerdrBusyState', 'Test-FmBackendHerdrEndpointGone',
    # projection lifecycle
    'New-FmBackendHerdrProjectionTask', 'Clear-FmBackendHerdrProjectionExact',
    'Get-FmBackendHerdrProjectionParentWorkspace', 'Test-FmBackendHerdrProjectionLiveBinding',
    'Undo-FmBackendHerdrProjectionReclaim', 'Restore-FmBackendHerdrProjectionTask',
    'Test-FmBackendHerdrProjectionFlatFallback', 'Test-FmBackendHerdrProjectionEndpointJournal',
    'Set-FmBackendHerdrProjectionOrder', 'Get-FmBackendHerdrProjectionOrderAnalysis',
    'Test-FmBackendHerdrIsParentWorkspace', 'Test-FmBackendHerdrNewChildLabel',
    'Test-FmBackendHerdrLegacyChildLabel', 'Test-FmBackendHerdrTopLevelParentLabel',
    # pane IO
    'Get-FmBackendHerdrCapture', 'Get-FmBackendHerdrCaptureAnsi',
    'Get-FmBackendHerdrCurrentPath', 'Get-FmBackendHerdrCurrentPathProbe',
    'Send-FmBackendHerdrTextLine', 'Send-FmBackendHerdrLiteral', 'Send-FmBackendHerdrKey',
    'Send-FmBackendHerdrTextSubmit', 'Get-FmBackendHerdrComposerState',
    'Test-FmBackendHerdrBorderedRow', 'Test-FmBackendHerdrPiSeparatorRow',
    'Get-FmBackendHerdrPiComposer', 'Get-FmBackendHerdrSubmitConfirmBudget',
    'Wait-FmBackendHerdrWorking',
    'Remove-FmBackendHerdrTarget', 'Remove-FmBackendHerdrTargetSerialized',
    # native event push
    'Get-FmBackendHerdrSocketPath', 'Test-FmBackendHerdrEventsCapable',
    'ConvertTo-FmBackendHerdrEventRecord', 'Get-FmBackendHerdrEventReaderCommand',
    'Get-FmBackendHerdrEscalationMarker', 'Select-FmBackendHerdrTransition',
    'Save-FmBackendHerdrTransition', 'Clear-FmBackendHerdrTransition',
    'Wait-FmBackendHerdrTransition', 'Get-FmBackendHerdrPipeName',
    'Connect-FmBackendHerdrEventStream', 'Read-FmBackendHerdrEventLine',
    'Disconnect-FmBackendHerdrEventStream', 'Get-FmBackendHerdrEventField',
    'Select-FmBackendHerdrLevelTransition'
)
