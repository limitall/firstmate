# fm-test-run.psm1 - every behavior of Firstmate's behavior-test runner:
# selection, the family map, portable lane composition, the coverage guard,
# timing markers, the JSON artifact, and bounded --jobs concurrency.
#
# Twin: bin/fm-test-run.sh
#
# bin/fm-test-run.ps1 is the executable half; it holds the CLI header (so
# --help stays byte-identical to the bash twin's) and nothing else. This
# module holds all of the logic, including `main`.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A MODULE + ENTRYPOINT PAIR WHEN THE BASH TWIN IS ONE FILE
#
# bin/fm-test-run.sh has no `BASH_SOURCE` main guard, so by the letter of
# docs/powershell-port.md it should have been a single .ps1. It is split for
# one measured reason: a pwsh process costs ~2.4s to start on this host, and
# behavior that lives only in a .ps1 can be exercised only by spawning one
# process per case. The differential suite drives ~30 cases; as a lone .ps1
# that is 75 seconds of pure interpreter startup, and the port doc's "batch
# pwsh" rule exists because suites built that way stop finishing at all.
# With `main` in a module, one pwsh imports it once and evaluates every case
# in-process. That is the same argument bin/fm-operational-input.ps1 records
# for the hybrid conversions, and this file follows its shape exactly.
#
# ---------------------------------------------------------------------------
# FUNCTION MAP (bash -> PowerShell)
#
#   usage                          Show-FmTestRunUsage
#   die                            throw [FmTestRunDie]::new(...)  (see below)
#   log                            Write-FmTestRunLog
#   now_iso                        Get-FmTestRunIsoTime
#   now_ms                         Get-FmTestRunEpochMs
#   family_for_basename            Get-FmTestRunFamily
#   expected_gate_skip_for_family  Get-FmTestRunExpectedGateSkip
#   list_known_families            Get-FmTestRunKnownFamily
#   list_known_lanes               Get-FmTestRunKnownLane
#   list_proven_isolated           Get-FmTestRunProvenIsolated
#   list_portable_parallel_1/2     Get-FmTestRunPortableShard -Index 1|2
#   portable_serial_weight_for     Get-FmTestRunPortableSerialWeight
#   portable_serial_assignments    Get-FmTestRunPortableSerialAssignment
#   portable_serial_shard_index    Get-FmTestRunPortableSerialShardIndex
#   is_proven_isolated_script      Test-FmTestRunProvenIsolated
#   all_repo_tests                 Get-FmTestRunRepoTest
#   normalize_script_path          ConvertTo-FmTestRunScriptPath
#   add_script                     Add-FmTestRunScript
#   select_all                     Select-FmTestRunAll
#   select_family                  Select-FmTestRunFamily
#   select_lane                    Select-FmTestRunLane
#   select_proven_isolated         Select-FmTestRunProvenIsolated
#   select_changed                 Select-FmTestRunChanged
#   families_for_test_reference    Get-FmTestRunFamilyForReference
#   families_for_changed_path      Get-FmTestRunFamilyForChangedPath
#   run_coverage_guard             Test-FmTestRunCoverage
#   apply_exclude_families         Remove-FmTestRunExcludedFamily
#   detect_gate_skip               Test-FmTestRunGateSkip
#   detect_gate_skip_token         Test-FmTestRunGateSkipToken
#   write_json_artifact            Write-FmTestRunTimingJson
#   aggregate_timing_json          Merge-FmTestRunTimingJson
#   family_bump                    Add-FmTestRunFamilyTotal
#   record_script_result           Register-FmTestRunResult
#   run_one_serial                 Invoke-FmTestRunSerialScript
#   the --jobs scheduler           Invoke-FmTestRunParallel
#   the argv loop + main flow      Invoke-FmTestRunMain
#   (no bash twin) dir mode        Get-FmTestRunDirMode
#   (no bash twin) inert probe     Test-FmTestRunModeEnforcementInert
#   (no bash twin) owner probes    Get-FmTestRunPathOwner / -CurrentOwner
#   (no bash twin) worker gate     Test-FmTestRunWorkerRoot
#   (no bash twin) child exec      Start-FmTestRunChild, Step-FmTestRunChild,
#                                  Get-FmTestRunChildOutput,
#                                  Invoke-FmTestRunScriptProcess
#   (no bash twin) worker reaper   Complete-FmTestRunWorker
#   (no bash twin) chmod 0700      Set-FmTestRunPrivateDirectory
#   (no bash twin) mkdir -p        New-FmTestRunDirectory
#   (no bash twin) python json     ConvertTo-FmTestRunJson (dump),
#                                  ConvertTo-FmTestRunJsonString,
#                                  ConvertFrom-FmTestRunJson (load),
#                                  Convert-FmTestRunJsonElement,
#                                  ConvertTo-FmTestRunInt (python int(x or 0))
#   (no bash twin) sort/comm/uniq  Get-FmTestRunSorted, Get-FmTestRunSortedUnique,
#                                  Get-FmTestRunSetDiff,
#                                  Get-FmTestRunSetIntersect,
#                                  Get-FmTestRunSetDuplicate,
#                                  Get-FmTestRunSetSymmetric
#   (no bash twin) case-pattern    Test-FmTestRunGlob, Test-FmTestRunGlobAny
#   (no bash twin) cd "$ROOT"      Resolve-FmTestRunPath
#   (no bash twin) basename        Get-FmTestRunBaseName
#
# ---------------------------------------------------------------------------
# THE MARKERS ARE AN INTERFACE, SO THEY ARE BUILT AS BYTES
#
# FM_TEST_BEGIN / FM_TEST_END / FM_TEST_SUMMARY / FM_TEST_SUMMARY_FAMILY /
# FM_TEST_SLOWEST / FM_TEST_COVERAGE / FM_TEST_AGGREGATE are parsed by CI and
# by the aggregate path in this same file. Every one is written through
# Write-FmOut (LF, UTF-8, no BOM) with the bash printf's field order and
# spacing reproduced literally. Write-Output is never used anywhere in this
# file: it emits CRLF on this host, which would split every marker line for a
# downstream `grep -E '^FM_TEST_END .+ exit=0 ...$'`.
#
# ---------------------------------------------------------------------------
# SORTING IS ORDINAL, BECAUSE `LC_ALL=C sort` IS
#
# Measured here: `Sort-Object -CaseSensitive` is still CULTURE-aware and puts
# 'arm' before 'Arm', while `LC_ALL=C sort` puts 'Arm' first. Every ordering in
# this file therefore goes through [System.StringComparer]::Ordinal.
#
# One deliberate exception, called out rather than hidden: the bash family
# summary uses `sort -t$'\t' -k1,1` with NO LC_ALL pin, so it collates in the
# caller's locale. For the fourteen family names this map can produce, C and
# en_GB order identically (checked pairwise), so ordinal is used there too.
#
# ---------------------------------------------------------------------------
# WHAT THIS TWIN DOES *NOT* NEED, AND THEREFORE CANNOT REFUSE
#
# The bash runner shells out to python3 three times: for millisecond time, for
# the timing artifact, and for --aggregate-json. Two of those are guarded by
# `command -v python3 || die`. PowerShell has millisecond time and a JSON
# writer in-process, so those two refusals are UNREACHABLE here. That is the
# only intended behavioral difference in the non-execution surface, and it is
# in the safe direction: the PS twin succeeds where the bash twin would refuse
# for want of an interpreter. ConvertTo-FmTestRunJson reproduces python's
# `json.dumps(obj, indent=2, sort_keys=True)` byte for byte so the artifacts
# themselves stay identical (contract 2) and a lane artifact written by either
# world aggregates in the other.
#
# One difference remains, and it runs the other way: ON WINDOWS THE BASH TWIN
# EMITS CRLF HERE AND THIS ONE DOES NOT. A native Windows python opens stdout
# and its output file in TEXT mode, so every "\n" it writes becomes "\r\n" -
# measured, the bash aggregate artifact is byte-for-byte this one except that
# all 96 lines end CRLF, and its FM_TEST_AGGREGATE line ends CRLF too. Contract
# 1 forbids reproducing that (a CR in a marker line is exactly the corruption
# class fm-common exists to prevent, and the Windows bash port already paid for
# it once with native jq's CRLF pipe output), so the twin writes LF and the
# differential normalizes the bash side rather than the PowerShell side. Off
# Windows python writes LF and the two agree with nothing normalized.
#
# ---------------------------------------------------------------------------
# THE --jobs WORKER-ISOLATION CHECK ON AN INERT-chmod FILESYSTEM
#
# The bash scheduler gives each worker a private mode-0700 root and then
# VERIFIES that mode, both when creating it (`chmod 0700 ... || die`) and after
# the worker finishes (`stat -c %a` must read 700). On Windows that check can
# never pass: Git Bash mounts drives and /tmp `noacl,posix=0,usertemp`, so
# chmod is accepted and provably changes nothing - measured here, `mkdir -p d;
# chmod 0700 d; stat -c %a d` prints 755.
#
# Silently dropping the check would delete a real isolation guarantee, and
# enforcing NTFS ACLs instead would make the PowerShell path refuse worker
# roots the bash path accepts - the exact failure docs/powershell-port.md
# "Things that must NOT be improved" and inventory R6 forbid, because both
# trees are live against the same machine during the transition.
#
# So this follows the precedent the bash tree already set for this identical
# situation (fm_pr_mode_enforcement_inert in bin/fm-pr-lib.sh, duplicated as
# fmx_mode_enforcement_inert in bin/fm-x-lib.sh): probe whether chmod is inert
# on that directory, and only when it provably is, accept the worker root on
# OWNERSHIP instead of on the mode bit. On a mode-honoring host the mode gate
# is unchanged and the probe never runs. The probe is duplicated here rather
# than imported for the same reason those two libs duplicate it from each
# other - bin/fm-test-run.sh has ZERO source edges, and adding one to
# fm-pr-lib.psm1 would invent a dependency the twin does not have.
#
# One consequence, stated because it is observable: tests/fm-test-run.test.sh
# makes the bash scheduler pass on Windows by putting a FAKE `stat` on PATH
# that prints 700. This twin reads the mode natively and never consults `stat`,
# so that fixture has no effect on it - it does not need one.
#
# ---------------------------------------------------------------------------
# HOW TEST SCRIPTS ARE EXECUTED
#
# Most of the suite is bash and will be for a long time, so a `.test.sh` is
# still run through Git Bash, located by fm-common's Get-FmBash (the operator
# override FM_BASH, then the well-known install layout, then PATH) rather than
# assuming a POSIX shell is on PATH - a hook or a herdr pane often has none.
# A `.test.ps1` runs under the pwsh that is running this module, so a converted
# suite inherits this exact interpreter version.
#
# The child's stdout and stderr are drained CONCURRENTLY into one buffer, in
# arrival order, by racing two ReadLineAsync tasks. Two properties of that
# differ from the bash twin's `2>&1` fd merge and are recorded rather than
# normalized away:
#   - merging happens at LINE granularity, not byte granularity, so two
#     half-lines written to different streams cannot interleave mid-line here;
#   - a final line with no trailing newline is captured, and gains one.
# Neither changes any verdict this runner computes: the gate-skip gate reads
# the first non-blank line, and the token gate matches anywhere in the output.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-test-run.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it: a .psm1
# resolves function names in its OWN scope. NO -Force, which is load-bearing
# rather than stylistic - a nested -Force REMOVES the already-loaded module
# before re-importing it, and that removal is global, so the .ps1 that imported
# fm-common.psm1 itself would lose Write-FmOut the moment it imported this one.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# The `die` twin. bash's die() prints one line and exits 2 from wherever it is
# called, including from three frames down inside the coverage guard. A typed
# exception is the only PowerShell spelling with that reach; Invoke-FmTestRunMain
# is the single place that catches it, prints the same line, and returns 2.
class FmTestRunDie : System.Exception {
    FmTestRunDie([string]$message) : base($message) { }
}

$script:FmTestRunPrefix = 'fm-test-run'
$script:FmTestRunJobsMax = 8

# --- the family map ----------------------------------------------------------
#
# Every arm of the bash `case` is a literal basename (no globs), so the twin is
# a lookup table rather than a pattern walk. Order within a family is the bash
# file's order, kept so a diff against the twin stays readable.

$script:FmTestRunFamilyMap = @{}
$script:FmTestRunFamilyOrder = @(
    @{ Family = 'pure-contract-unit'; Names = @(
            'fm-arm-pretool-check.test.sh', 'fm-ask-user-authority.test.sh',
            'fm-brief.test.sh', 'fm-vendor-auth-probe.test.sh',
            'fm-calm-pi-extension.test.sh', 'fm-cd-pretool-check.test.sh',
            'fm-composer-ghost.test.sh', 'fm-composer-lib.test.sh',
            'fm-crew-state.test.sh', 'fm-decision-hold-lifecycle.test.sh',
            'fm-documentation-audiences.test.sh', 'fm-ensure-agents-md.test.sh',
            'fm-grok-harness.test.sh',
            'fm-kimi-harness.test.sh', 'fm-muse-harness.test.sh',
            'fm-herdr-lab.test.sh', 'fm-lint.test.sh',
            'fm-operational-input.test.sh', 'fm-pi-primary-types.test.sh',
            'fm-send-popup-settle.test.sh', 'fm-send-settle.test.sh',
            'fm-subagent-pretool-check.test.sh',
            'fm-supervision-instructions.test.sh', 'fm-tmux-submit-busy.test.sh',
            'fm-transition-lib.test.sh',
            'fm-test-run.test.sh', 'fm-test-isolation-proof.test.sh') }
    @{ Family = 'watcher-wake-lock'; Names = @(
            'fm-daemon.test.sh', 'fm-guard-stale-banner.test.sh',
            'fm-pi-watch-extension.test.sh', 'fm-supervision-events.test.sh',
            'fm-turnend-guard.test.sh', 'fm-wake-daemon-lifecycle-e2e.test.sh',
            'fm-wake-queue.test.sh', 'fm-watch-checkpoint.test.sh',
            'fm-watch-triage.test.sh', 'fm-watcher-lock.test.sh') }
    @{ Family = 'real-herdr-gated'; Names = @(
            'fm-afk-inject-herdr-e2e.test.sh', 'fm-afk-launch.test.sh',
            'fm-backend-autodetect-smoke.test.sh',
            'fm-backend-herdr-eventwait-smoke.test.sh',
            'fm-backend-herdr-presentation-e2e.test.sh',
            'fm-backend-herdr-launcher-workspace-e2e.test.sh',
            'fm-backend-herdr-prune-safety-e2e.test.sh',
            'fm-backend-herdr-respawn-idem-e2e.test.sh',
            'fm-herdr-session-cleanup-e2e.test.sh',
            'fm-backend-herdr-smoke.test.sh',
            'fm-backend-herdr-workspace-per-home-e2e.test.sh') }
    @{ Family = 'secondmate'; Names = @(
            'fm-backlog-handoff.test.sh', 'fm-secondmate-harness.test.sh',
            'fm-secondmate-lifecycle-e2e.test.sh', 'fm-secondmate-liveness.test.sh',
            'fm-secondmate-safety.test.sh', 'fm-secondmate-sync.test.sh',
            'fm-startup-memory-budget.test.sh',
            'fm-send-secondmate-marker.test.sh',
            'fm-shared-captain-inheritance.test.sh') }
    @{ Family = 'session-bootstrap'; Names = @(
            'fm-bootstrap.test.sh', 'fm-fleet-sync.test.sh', 'fm-gate-refuse.test.sh',
            'fm-gotmp.test.sh', 'fm-session-start.test.sh',
            'fm-sessionstart-nudge.test.sh', 'fm-tangle-guard.test.sh',
            'fm-update.test.sh') }
    @{ Family = 'live-harness-optin'; Names = @(
            'fm-afk-pi-herdr-return-e2e.test.sh',
            'fm-codex-continuity-live-e2e.test.sh',
            'fm-grok-continuity-live-e2e.test.sh',
            'fm-grok-stop-live-e2e.test.sh', 'fm-muse-signals-live-e2e.test.sh',
            'fm-opencode-primary-live-e2e.test.sh',
            'fm-pi-primary-live-e2e.test.sh',
            'fm-quota-array-dispatch-live-e2e.test.sh',
            'fm-send-secondmate-marker-herdr-e2e.test.sh') }
    @{ Family = 'backend-dispatch'; Names = @(
            'fm-backend-herdr.test.sh', 'fm-backend-tmux-smoke.test.sh',
            'fm-backend.test.sh', 'fm-herdr-session-cleanup.test.sh',
            'fm-send-strict.test.sh', 'fm-spawn-batch.test.sh',
            'fm-spawn-dispatch-profile.test.sh', 'fm-spawn-worktree-settle.test.sh',
            'fm-teardown-endpoint-safety.test.sh') }
    @{ Family = 'pr-forge'; Names = @(
            'fm-pr-check-security.test.sh', 'fm-pr-merge.test.sh',
            'fm-review-diff.test.sh', 'fm-teardown.test.sh', 'fm-x-mode.test.sh') }
    @{ Family = 'afk'; Names = @('fm-afk-inject-e2e.test.sh', 'fm-afk-return.test.sh') }
    @{ Family = 'snapshot-bearings'; Names = @(
            'fm-bearings-snapshot.test.sh', 'fm-fleet-snapshot-view.test.sh') }
    @{ Family = 'cmux'; Names = @('fm-backend-cmux.test.sh', 'fm-backend-cmux-smoke.test.sh') }
    @{ Family = 'zellij'; Names = @('fm-backend-zellij.test.sh', 'fm-backend-zellij-smoke.test.sh') }
    @{ Family = 'orca'; Names = @('fm-backend-orca.test.sh') }
)
foreach ($fmTestRunGroup in $script:FmTestRunFamilyOrder) {
    foreach ($fmTestRunName in $fmTestRunGroup['Names']) {
        $script:FmTestRunFamilyMap[$fmTestRunName] = $fmTestRunGroup['Family']
    }
}

$script:FmTestRunKnownFamilies = @(
    'pure-contract-unit', 'watcher-wake-lock', 'real-herdr-gated', 'secondmate',
    'session-bootstrap', 'live-harness-optin', 'backend-dispatch', 'pr-forge',
    'afk', 'snapshot-bearings', 'cmux', 'zellij', 'orca', 'unclassified'
)

# Not a static list: the twin's list_known_lanes GENERATES the CI serial shard
# names from PORTABLE_SERIAL_SHARDS, so hard-coding them here would let the
# advertised lanes and the lanes that actually resolve drift apart the moment
# that count changes. Get-FmTestRunKnownLane builds them the same way.
$script:FmTestRunKnownLanes = @(
    'portable-parallel-1', 'portable-parallel-2', 'portable-serial'
)

# Exact proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
$script:FmTestRunProvenIsolated = @(
    'tests/fm-arm-pretool-check.test.sh'
    'tests/fm-backend-herdr.test.sh'
    'tests/fm-brief.test.sh'
    'tests/fm-cd-pretool-check.test.sh'
    'tests/fm-composer-ghost.test.sh'
    'tests/fm-composer-lib.test.sh'
    'tests/fm-crew-state.test.sh'
    'tests/fm-decision-hold-lifecycle.test.sh'
    'tests/fm-ensure-agents-md.test.sh'
    'tests/fm-grok-harness.test.sh'
    'tests/fm-herdr-lab.test.sh'
    'tests/fm-lint.test.sh'
    'tests/fm-pi-primary-types.test.sh'
    'tests/fm-pr-merge.test.sh'
    'tests/fm-review-diff.test.sh'
    'tests/fm-send-popup-settle.test.sh'
    'tests/fm-send-settle.test.sh'
    'tests/fm-send-strict.test.sh'
    'tests/fm-spawn-batch.test.sh'
    'tests/fm-supervision-instructions.test.sh'
    'tests/fm-test-run.test.sh'
    'tests/fm-tmux-submit-busy.test.sh'
    'tests/fm-transition-lib.test.sh'
    'tests/fm-x-mode.test.sh'
)

# Portable parallel shard 1: LPT balance of the proven-isolated set using the
# current concurrent-proof durations in docs/fm-test-isolation-proof.json.
# Execution order is longest first so wall-clock stays near the balanced sum.
$script:FmTestRunPortableShard1 = @(
    'tests/fm-x-mode.test.sh'
    'tests/fm-cd-pretool-check.test.sh'
    'tests/fm-decision-hold-lifecycle.test.sh'
    'tests/fm-test-run.test.sh'
    'tests/fm-composer-ghost.test.sh'
    'tests/fm-grok-harness.test.sh'
    'tests/fm-lint.test.sh'
    'tests/fm-pi-primary-types.test.sh'
    'tests/fm-review-diff.test.sh'
    'tests/fm-brief.test.sh'
    'tests/fm-transition-lib.test.sh'
)

# Portable parallel shard 2: the complementary LPT half of the proven set.
$script:FmTestRunPortableShard2 = @(
    'tests/fm-backend-herdr.test.sh'
    'tests/fm-arm-pretool-check.test.sh'
    'tests/fm-crew-state.test.sh'
    'tests/fm-herdr-lab.test.sh'
    'tests/fm-pr-merge.test.sh'
    'tests/fm-send-popup-settle.test.sh'
    'tests/fm-tmux-submit-busy.test.sh'
    'tests/fm-send-settle.test.sh'
    'tests/fm-send-strict.test.sh'
    'tests/fm-spawn-batch.test.sh'
    'tests/fm-supervision-instructions.test.sh'
    'tests/fm-ensure-agents-md.test.sh'
    'tests/fm-composer-lib.test.sh'
)

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
$script:FmTestRunPortableSerialShards = 4

# Balance hint for a portable-serial script with no measured duration, close to
# the measured per-script mean so a newly added test neither starves nor
# overloads the shard it lands in.
$script:FmTestRunPortableSerialDefaultWeightMs = 20000

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifact recorded in docs/fm-test-portable-shards.md. These are balance hints
# only: the shard partition stays complete and disjoint whatever they say, so a
# stale hint costs balance rather than coverage. That doc owns the refresh
# procedure.
#
# A hashtable rather than the twin's here-doc because the bash lookup is a
# first-match linear scan over a list with no duplicate key, which an ordinal
# hashtable reproduces exactly and in one step.
$script:FmTestRunPortableSerialWeightHint = @{
    'tests/fm-afk-inject-e2e.test.sh'                   = 34019
    'tests/fm-afk-pi-herdr-return-e2e.test.sh'          = 42
    'tests/fm-afk-return.test.sh'                       = 1105
    'tests/fm-ask-user-authority.test.sh'               = 68
    'tests/fm-backend-cmux-smoke.test.sh'               = 29
    'tests/fm-backend-cmux.test.sh'                     = 2349
    'tests/fm-backend-herdr-focus-flash-e2e.test.sh'    = 21
    'tests/fm-backend-orca.test.sh'                     = 12041
    'tests/fm-backend-tmux-smoke.test.sh'               = 314
    'tests/fm-backend-zellij-smoke.test.sh'             = 21
    'tests/fm-backend-zellij.test.sh'                   = 4225
    'tests/fm-backend.test.sh'                          = 16370
    'tests/fm-backlog-handoff.test.sh'                  = 2786
    'tests/fm-bearings-snapshot.test.sh'                = 60103
    'tests/fm-bootstrap.test.sh'                        = 21912
    'tests/fm-busy-adapter-wiring.test.sh'              = 13962
    'tests/fm-busy-state.test.sh'                       = 607
    'tests/fm-calm-pi-extension.test.sh'                = 203
    'tests/fm-claude-stop-autoarm-live-e2e.test.sh'     = 19
    'tests/fm-claude-stop-autoarm.test.sh'              = 60521
    'tests/fm-codex-continuity-live-e2e.test.sh'        = 19
    'tests/fm-daemon.test.sh'                           = 15140
    'tests/fm-documentation-audiences.test.sh'          = 572
    'tests/fm-fleet-snapshot-view.test.sh'              = 5902
    'tests/fm-fleet-sync.test.sh'                       = 16417
    'tests/fm-gate-refuse.test.sh'                      = 2839
    'tests/fm-gitignore-config.test.sh'                 = 28
    'tests/fm-gotmp.test.sh'                            = 308
    'tests/fm-grok-continuity-live-e2e.test.sh'         = 19
    'tests/fm-grok-stop-live-e2e.test.sh'               = 19
    'tests/fm-guard-stale-banner.test.sh'               = 2917
    'tests/fm-herdr-session-cleanup.test.sh'            = 4802
    'tests/fm-kimi-harness.test.sh'                     = 12590
    'tests/fm-opencode-primary-live-e2e.test.sh'        = 18
    'tests/fm-operational-input.test.sh'                = 184
    'tests/fm-pending-reply.test.sh'                    = 7328
    'tests/fm-pi-primary-live-e2e.test.sh'              = 19
    'tests/fm-pi-watch-extension.test.sh'               = 16386
    'tests/fm-pr-check-security.test.sh'                = 199573
    'tests/fm-procevent.test.sh'                        = 42789
    'tests/fm-public-followup.test.sh'                  = 23365
    'tests/fm-quota-array-dispatch-live-e2e.test.sh'    = 19
    'tests/fm-secondmate-harness.test.sh'               = 87895
    'tests/fm-secondmate-lifecycle-e2e.test.sh'         = 4929
    'tests/fm-secondmate-liveness.test.sh'              = 12553
    'tests/fm-secondmate-safety.test.sh'                = 24432
    'tests/fm-secondmate-sync.test.sh'                  = 12289
    'tests/fm-send-secondmate-marker-herdr-e2e.test.sh' = 27
    'tests/fm-send-secondmate-marker.test.sh'           = 2136
    'tests/fm-session-start.test.sh'                    = 37289
    'tests/fm-sessionstart-nudge.test.sh'               = 264
    'tests/fm-shared-captain-inheritance.test.sh'       = 3506
    'tests/fm-spawn-dispatch-profile.test.sh'           = 41351
    'tests/fm-spawn-worktree-settle.test.sh'            = 4598
    'tests/fm-startup-memory-budget.test.sh'            = 4260
    'tests/fm-subagent-pretool-check.test.sh'           = 901
    'tests/fm-supervision-events.test.sh'               = 413
    'tests/fm-tangle-guard.test.sh'                     = 7230
    'tests/fm-teardown-endpoint-safety.test.sh'         = 1073
    'tests/fm-teardown.test.sh'                         = 23237
    'tests/fm-test-isolation-proof.test.sh'             = 326
    'tests/fm-turnend-guard.test.sh'                    = 5986
    'tests/fm-update.test.sh'                           = 1894
    'tests/fm-vendor-auth-probe.test.sh'                = 42796
    'tests/fm-wake-daemon-lifecycle-e2e.test.sh'        = 4284
    'tests/fm-wake-queue.test.sh'                       = 22787
    'tests/fm-watch-checkpoint.test.sh'                 = 3943
    'tests/fm-watch-triage.test.sh'                     = 113051
    'tests/fm-watcher-lock.test.sh'                     = 98342
}

# --- reporters ---------------------------------------------------------------

<#
.SYNOPSIS
The log() twin: one "fm-test-run: <message>" line on stderr.
.DESCRIPTION
The prefix is the literal bash spelling, not the running script's leaf name -
Write-FmLog would print "fm-test-run.ps1:" and every CI grep for the bash
prefix would miss.
#>
function Write-FmTestRunLog {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message)
    Write-FmErr "${script:FmTestRunPrefix}: $Message"
}

<#
.SYNOPSIS
The usage() twin: this command's own header comment block, on stderr.
.DESCRIPTION
bash prints it with

    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"

- skip line 1 (the shebang), print every following comment line with its "# "
  removed, stop at the first line that is not a comment.

bin/fm-test-run.ps1 is laid out so that EXACT rule reproduces the bash output
byte for byte: its line 1 is `#Requires -Version 7.0` (the shebang's
positional stand-in, skipped the same way), lines 2..n are the bash header
verbatim, and a blank line ends the block where `set -eu` ends it in bash.
The conversion notes live below that boundary, and in this module, so they
cannot leak into a CLI surface contract 4 requires to be identical.
#>
function Show-FmTestRunUsage {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$CommandPath)

    if ([string]::IsNullOrEmpty($CommandPath)) {
        $CommandPath = Join-Path $PSScriptRoot 'fm-test-run.ps1'
    }
    $lines = (Get-FmFileLines $CommandPath)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.StartsWith('#')) { break }
        Write-FmErr ($line -replace '^# ?', '')
    }
}

# --- time --------------------------------------------------------------------

<#
.SYNOPSIS
The now_iso twin: `date -u +%Y-%m-%dT%H:%M:%SZ`.
#>
function Get-FmTestRunIsoTime {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
The now_ms twin: epoch milliseconds.
.DESCRIPTION
bash shells out to python3 for this and falls back to whole seconds x1000 when
python3 is absent. PowerShell has the clock in-process, so the coarse fallback
has no counterpart here and durations are always millisecond-resolved.
#>
function Get-FmTestRunEpochMs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Ms is the unit millisecond, not a plural: the analyzer reads the trailing s as one. The name is the bash twins now_ms verbatim so the pairing stays greppable, and a singular rewording would name a different quantity.')]
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

# --- paths and patterns ------------------------------------------------------

<#
.SYNOPSIS
The basename twin for the '/'-spelled paths this runner handles.
#>
function Get-FmTestRunBaseName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $trimmed = $Path.TrimEnd('/', '\')
    if ($trimmed -eq '') { return $Path }
    $idx = $trimmed.LastIndexOfAny(@([char]'/', [char]'\'))
    if ($idx -lt 0) { return $trimmed }
    return $trimmed.Substring($idx + 1)
}

<#
.SYNOPSIS
Resolve a runner-relative path against the repo root, in native form.
.DESCRIPTION
The bash twin opens with `cd "$ROOT"`, so every relative path it is handed -
a script path, --json, an aggregate input - resolves against the repo root
rather than the caller's directory. This twin deliberately does NOT change the
process directory: PowerShell's location and .NET's current directory are
separate, so a relative path handed to [System.IO.File] would silently resolve
against the WRONG one. Joining explicitly is the only spelling that cannot
drift.
#>
function Resolve-FmTestRunPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $native = ConvertTo-FmNativePath $Path
    if ([System.IO.Path]::IsPathRooted($native)) { return $native }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $native))
}

<#
.SYNOPSIS
Match a value against one bash `case` pattern.
.DESCRIPTION
The changed-path map is the only place this runner pattern-matches, and its
patterns use nothing but literals and `*` - which in a bash `case` matches any
string INCLUDING '/', so `bin/*` really does cover `bin/backends/herdr.sh`.
Splitting on '*' and rejoining the escaped literals with '.*' is exact and,
unlike escaping then un-escaping the star, cannot produce a nested quantifier.
Case-sensitive, as bash is.
#>
function Test-FmTestRunGlob {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory, Position = 1)][string]$Pattern
    )
    $parts = @($Pattern.Split('*'))
    $escaped = @($parts | ForEach-Object { [System.Text.RegularExpressions.Regex]::Escape($_) })
    $rx = '^' + ($escaped -join '.*') + '$'
    return [System.Text.RegularExpressions.Regex]::IsMatch($Value, $rx)
}

# Match against any of a bash `case` arm's '|'-separated patterns.
function Test-FmTestRunGlobAny {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory, Position = 1)][string[]]$Pattern
    )
    foreach ($p in $Pattern) {
        if (Test-FmTestRunGlob -Value $Value -Pattern $p) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
The normalize_script_path twin.
.DESCRIPTION
Four arms, in the bash order:
  /*              absolute - untouched
  tests/*|./tests/*  strip a leading './'
  *.test.sh       prefixed with tests/ only when tests/<p> really exists
  *               untouched
A Windows drive path (C:/tmp/x.test.sh) matches none of the first two and
falls through the third with tests/C:/... absent, so it is returned unchanged -
the same answer bash gives it, for the same reason.
#>
function ConvertTo-FmTestRunScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )
    if ($Path.StartsWith('/')) { return $Path }
    if ($Path.StartsWith('tests/')) { return $Path }
    if ($Path.StartsWith('./tests/')) { return $Path.Substring(2) }
    if ($Path.EndsWith('.test.sh')) {
        $candidate = [System.IO.Path]::Combine($Root, 'tests', $Path)
        if ([System.IO.File]::Exists($candidate)) { return "tests/$Path" }
    }
    return $Path
}

# --- set primitives (the sort/comm/uniq the guard is written in) -------------

<#
.SYNOPSIS
The `LC_ALL=C sort -u` twin.
#>
function Get-FmTestRunSortedUnique {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Value = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $list = [System.Collections.Generic.List[string]]::new()
    # The $null skip is the "@() returned from a function arrives as $null" trap:
    # a caller that passes the result of a function which produced nothing binds
    # $null here, and @($null) is a ONE-element array holding $null - which would
    # otherwise sort in as a phantom empty line.
    foreach ($v in @($Value)) { if ($null -ne $v -and $seen.Add($v)) { $list.Add($v) } }
    $list.Sort([System.StringComparer]::Ordinal)
    return @($list)
}

<#
.SYNOPSIS
The `LC_ALL=C sort` twin, duplicates retained.
#>
function Get-FmTestRunSorted {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Value = @())
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($v in @($Value)) { if ($null -ne $v) { $list.Add($v) } }
    $list.Sort([System.StringComparer]::Ordinal)
    return @($list)
}

# `comm -23 a b`: lines only in the left set. Inputs are already unique+sorted.
function Get-FmTestRunSetDiff {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Left = @(),
        [Parameter(Position = 1)][AllowNull()][AllowEmptyCollection()][string[]]$Right = @()
    )
    $r = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Right), [System.StringComparer]::Ordinal)
    return @(@($Left) | Where-Object { -not $r.Contains($_) })
}

# `comm -12 a b`: lines in both sets.
function Get-FmTestRunSetIntersect {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Left = @(),
        [Parameter(Position = 1)][AllowNull()][AllowEmptyCollection()][string[]]$Right = @()
    )
    $r = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Right), [System.StringComparer]::Ordinal)
    return @(@($Left) | Where-Object { $r.Contains($_) })
}

<#
.SYNOPSIS
The `uniq -d` twin: one copy of each value that appears more than once.
.DESCRIPTION
Input must already be sorted, exactly as `uniq` requires.
#>
function Get-FmTestRunSetDuplicate {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Value = @())
    $out = [System.Collections.Generic.List[string]]::new()
    $values = @($Value)
    $i = 0
    while ($i -lt $values.Count) {
        $j = $i + 1
        while ($j -lt $values.Count -and [string]::Equals($values[$j], $values[$i], [System.StringComparison]::Ordinal)) { $j++ }
        if (($j - $i) -gt 1) { $out.Add($values[$i]) }
        $i = $j
    }
    return @($out)
}

<#
.SYNOPSIS
The `comm -3 a b` twin: lines unique to one side, column 2 TAB-indented.
.DESCRIPTION
Used only by the coverage guard's isolation-proof cross-check, whose diagnostic
is compared byte for byte against the bash twin's. `comm` emits unique-to-left
lines in column 1 and unique-to-right lines in column 2, and column 2 carries
exactly one leading TAB because column 1 is empty and suppressed.
#>
function Get-FmTestRunSetSymmetric {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Left = @(),
        [Parameter(Position = 1)][AllowNull()][AllowEmptyCollection()][string[]]$Right = @()
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $l = @($Left); $r = @($Right)
    $i = 0; $j = 0
    while ($i -lt $l.Count -or $j -lt $r.Count) {
        if ($i -ge $l.Count) { $out.Add("`t" + $r[$j]); $j++; continue }
        if ($j -ge $r.Count) { $out.Add($l[$i]); $i++; continue }
        $cmp = [System.StringComparer]::Ordinal.Compare($l[$i], $r[$j])
        if ($cmp -lt 0) { $out.Add($l[$i]); $i++ }
        elseif ($cmp -gt 0) { $out.Add("`t" + $r[$j]); $j++ }
        else { $i++; $j++ }
    }
    return @($out)
}

# --- families ----------------------------------------------------------------

<#
.SYNOPSIS
The family_for_basename twin. Unmapped basenames are 'unclassified'.
#>
function Get-FmTestRunFamily {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$BaseName)
    if ($script:FmTestRunFamilyMap.ContainsKey($BaseName)) {
        return [string]$script:FmTestRunFamilyMap[$BaseName]
    }
    return 'unclassified'
}

<#
.SYNOPSIS
The expected_gate_skip_for_family twin.
#>
function Get-FmTestRunExpectedGateSkip {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Family)
    switch ($Family) {
        'real-herdr-gated' { return 'herdr' }
        'live-harness-optin' { return 'optin-env' }
        'cmux' { return 'optional-binary' }
        'zellij' { return 'optional-binary' }
        'orca' { return 'optional-binary' }
        'snapshot-bearings' { return 'optional-binary' }
        default { return 'none' }
    }
}

function Get-FmTestRunKnownFamily {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @($script:FmTestRunKnownFamilies)
}

function Get-FmTestRunKnownLane {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $script:FmTestRunKnownLanes) { $list.Add($l) }
    for ($i = 1; $i -le $script:FmTestRunPortableSerialShards; $i++) {
        $list.Add("portable-serial-{0}of{1}" -f $i, $script:FmTestRunPortableSerialShards)
    }
    $list.Add('real-herdr-gated')
    return , $list.ToArray()
}

<#
.SYNOPSIS
The portable_serial_weight_for twin: the measured hint for <Path>, or the
default weight when the partition has never measured it.
#>
function Get-FmTestRunPortableSerialWeight {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ($script:FmTestRunPortableSerialWeightHint.ContainsKey($Path)) {
        return [int]$script:FmTestRunPortableSerialWeightHint[$Path]
    }
    return [int]$script:FmTestRunPortableSerialDefaultWeightMs
}

function Get-FmTestRunProvenIsolated {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @($script:FmTestRunProvenIsolated)
}

function Get-FmTestRunPortableShard {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][int]$Index)
    if ($Index -eq 1) { return @($script:FmTestRunPortableShard1) }
    return @($script:FmTestRunPortableShard2)
}

function Test-FmTestRunProvenIsolated {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    foreach ($p in $script:FmTestRunProvenIsolated) {
        if ([string]::Equals($p, $Path, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# --- selection ---------------------------------------------------------------

<#
.SYNOPSIS
The all_repo_tests twin: every tests/*.test.sh, LC_ALL=C sorted.
#>
function Get-FmTestRunRepoTest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)
    $dir = [System.IO.Path]::Combine($Root, 'tests')
    if (-not [System.IO.Directory]::Exists($dir)) { return @() }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, '*.test.sh')) {
        # EnumerateFiles yields files only, which is the `[ -f "$f" ]` guard.
        $found.Add('tests/' + [System.IO.Path]::GetFileName($f))
    }
    return @(Get-FmTestRunSorted $found)
}

<#
.SYNOPSIS
The add_script twin: append a normalized path unless it is already selected.
.DESCRIPTION
Order of first appearance is preserved, which is what makes the LPT shard order
observable in --list.
#>
function Add-FmTestRunScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )
    $p = ConvertTo-FmTestRunScriptPath -Root $Context['Root'] -Path $Path
    foreach ($existing in $Context['Scripts']) {
        if ([string]::Equals($existing, $p, [System.StringComparison]::Ordinal)) { return }
    }
    $Context['Scripts'].Add($p)
}

function Select-FmTestRunAll {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)
    foreach ($s in (Get-FmTestRunRepoTest $Context['Root'])) {
        if ($s -ne '') { Add-FmTestRunScript -Context $Context -Path $s }
    }
}

function Select-FmTestRunProvenIsolated {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)
    foreach ($s in $script:FmTestRunProvenIsolated) {
        if ($s -ne '') { Add-FmTestRunScript -Context $Context -Path $s }
    }
}

function Select-FmTestRunFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Family
    )
    if ([string]::IsNullOrEmpty($Family)) { throw [FmTestRunDie]::new('--family requires a name') }
    $found = $false
    foreach ($s in (Get-FmTestRunRepoTest $Context['Root'])) {
        if ($s -eq '') { continue }
        if ((Get-FmTestRunFamily (Get-FmTestRunBaseName $s)) -eq $Family) {
            Add-FmTestRunScript -Context $Context -Path $s
            $found = $true
        }
    }
    if (-not $found) { throw [FmTestRunDie]::new("no tests mapped to family '$Family'") }
}

<#
.SYNOPSIS
The portable_serial_assignments twin: one @{ Shard = <int>; Path = <string> }
record per portable-serial script, longest-processing-time assigned to the
configured shard count.
.DESCRIPTION
Deterministic in both worlds, which is the whole point - two CI runners must
partition the same lane the same way from the same source, with no shared state
between them:
  - candidates are ordered by hint DESCENDING then path ASCENDING. The twin
    spells that `sort -t\t -k1,1nr -k2,2` under LC_ALL=C, so the tie-break is an
    ORDINAL string comparison, not a culture-aware one. It is reproduced as an
    ordinal sort by path followed by a STABLE numeric sort by weight descending,
    which yields the same total order without a custom comparer;
  - ties between equally loaded bins always take the LOWEST bin index, because
    the bash scan starts at bin 1 and only a STRICTLY smaller load displaces it.
#>
function Get-FmTestRunPortableSerialAssignment {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)

    # list_portable_serial: the complete suite minus the proven-isolated set and
    # minus the Herdr lane. Same predicate as the 'portable-serial' branch below,
    # deliberately not routed through Select-FmTestRunLane, which would mutate
    # the caller's selection.
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($s in (Get-FmTestRunRepoTest $Context['Root'])) {
        if ($s -eq '') { continue }
        if ((Get-FmTestRunFamily (Get-FmTestRunBaseName $s)) -eq 'real-herdr-gated') { continue }
        if (Test-FmTestRunProvenIsolated $s) { continue }
        $candidates.Add($s)
    }

    $ordered = @(@(Get-FmTestRunSorted $candidates) |
        ForEach-Object { [pscustomobject]@{ Weight = (Get-FmTestRunPortableSerialWeight $_); Path = $_ } } |
        Sort-Object -Property Weight -Descending -Stable)

    $shards = $script:FmTestRunPortableSerialShards
    # 1-based like the bash array, so index 0 is never read.
    $loads = [long[]]::new($shards + 1)
    $out = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in $ordered) {
        $best = 1
        $bestLoad = $loads[1]
        for ($i = 2; $i -le $shards; $i++) {
            if ($loads[$i] -lt $bestLoad) {
                $bestLoad = $loads[$i]
                $best = $i
            }
        }
        $loads[$best] = $bestLoad + [long]$item.Weight
        $out.Add(@{ Shard = $best; Path = [string]$item.Path })
    }
    return , $out.ToArray()
}

<#
.SYNOPSIS
The portable_serial_shard_index twin: <k> from a "portable-serial-<k>of<n>"
lane, as the STRING the twin echoes.
.DESCRIPTION
Refuses when <n> disagrees with this runner's configured count, so a CI matrix
built for a different shard count fails loudly instead of dropping tests.

The value stays a STRING because the twin's caller then compares it to the
assignment's shard column with `[ "$idx" = "$shard" ]` - a string test. So
`portable-serial-01of4` passes every numeric check here and then matches no
assignment, and the lane dies as "selected no tests". That is the twin's exact
behavior and it is reproduced rather than tidied up.

Splitting is on the FIRST "of": `${spec%%of*}` keeps what precedes it and
`${spec#*of}` keeps what follows it. The digit tests are the twin's
`''|*[!0-9]*` - digits only, and a leading zero is not rejected here.
#>
function Get-FmTestRunPortableSerialShardIndex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Lane)

    $shards = $script:FmTestRunPortableSerialShards
    $unknown = "unknown lane '$Lane' (see --list-lanes)"
    $spec = $Lane.Substring('portable-serial-'.Length)
    $at = $spec.IndexOf('of', [System.StringComparison]::Ordinal)
    if ($at -lt 0) { throw [FmTestRunDie]::new($unknown) }
    $index = $spec.Substring(0, $at)
    $count = $spec.Substring($at + 2)
    foreach ($part in @($index, $count)) {
        if ($part -eq '') { throw [FmTestRunDie]::new($unknown) }
        foreach ($c in $part.ToCharArray()) {
            if ($c -lt '0' -or $c -gt '9') { throw [FmTestRunDie]::new($unknown) }
        }
    }
    # BigInteger rather than [int] so a digit string too long for a machine word
    # is still COMPARED rather than throwing a conversion error the twin never
    # produces.
    $countValue = [System.Numerics.BigInteger]::Parse($count)
    if ($countValue -ne [System.Numerics.BigInteger]$shards) {
        throw [FmTestRunDie]::new(
            "lane '$Lane' asks for $count portable serial shards but this runner is configured for $shards (see --list-lanes)")
    }
    $indexValue = [System.Numerics.BigInteger]::Parse($index)
    if ($indexValue -lt [System.Numerics.BigInteger]1 -or $indexValue -gt [System.Numerics.BigInteger]$shards) {
        throw [FmTestRunDie]::new("lane '$Lane' shard index is outside 1..$shards (see --list-lanes)")
    }
    return $index
}

function Select-FmTestRunLane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Lane
    )
    $found = $false
    switch ($Lane) {
        'portable-parallel-1' {
            foreach ($s in (Get-FmTestRunPortableShard 1)) {
                if ($s -eq '') { continue }
                Add-FmTestRunScript -Context $Context -Path $s
                $found = $true
            }
        }
        'portable-parallel-2' {
            foreach ($s in (Get-FmTestRunPortableShard 2)) {
                if ($s -eq '') { continue }
                Add-FmTestRunScript -Context $Context -Path $s
                $found = $true
            }
        }
        'portable-serial' {
            # Everything in the complete suite that is not proven-isolated and not
            # real-herdr-gated. Watcher/lock/AFK/tmux/daemon/ambiguous/stateful work
            # stays here, serial only.
            foreach ($s in (Get-FmTestRunRepoTest $Context['Root'])) {
                if ($s -eq '') { continue }
                if ((Get-FmTestRunFamily (Get-FmTestRunBaseName $s)) -eq 'real-herdr-gated') { continue }
                if (Test-FmTestRunProvenIsolated $s) { continue }
                Add-FmTestRunScript -Context $Context -Path $s
                $found = $true
            }
        }
        'real-herdr-gated' {
            Select-FmTestRunFamily -Context $Context -Family 'real-herdr-gated'
            $found = $true
        }
        default {
            # The twin's `portable-serial-*)` arm, which sits AFTER the exact
            # `portable-serial)` arm in its case - so the exact names above still
            # win, and only a shard name reaches here. One separate-runner shard
            # of the same remainder, still serial in itself.
            if ($Lane.StartsWith('portable-serial-', [System.StringComparison]::Ordinal)) {
                $shard = Get-FmTestRunPortableSerialShardIndex -Lane $Lane
                foreach ($assignment in @(Get-FmTestRunPortableSerialAssignment -Context $Context)) {
                    $path = [string]$assignment['Path']
                    if ($path -eq '') { continue }
                    if ([string]::Equals([string]$assignment['Shard'], $shard,
                            [System.StringComparison]::Ordinal)) {
                        Add-FmTestRunScript -Context $Context -Path $path
                        $found = $true
                    }
                }
            } else {
                throw [FmTestRunDie]::new("unknown lane '$Lane' (see --list-lanes)")
            }
        }
    }
    if (-not $found) { throw [FmTestRunDie]::new("lane '$Lane' selected no tests") }
}

<#
.SYNOPSIS
The families_for_test_reference twin: families of every suite that mentions
<needle>, and $null when no suite does.
.DESCRIPTION
`grep -Fq` is a FIXED-STRING search of the whole file, so the twin is an
ordinal IndexOf over the file text. Returning $null distinguishes "no suite
references this" (the bash non-zero return, which makes the caller emit an
__unmapped__ marker) from "referenced, but its family is already listed".
#>
function Get-FmTestRunFamilyForReference {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Needle
    )
    $out = [System.Collections.Generic.List[string]]::new()
    $found = $false
    foreach ($s in (Get-FmTestRunRepoTest $Root)) {
        if ($s -eq '') { continue }
        $text = Get-FmFileText ([System.IO.Path]::Combine($Root, $s))
        if ($text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) {
            $out.Add((Get-FmTestRunFamily (Get-FmTestRunBaseName $s)))
            $found = $true
        }
    }
    if (-not $found) { return $null }
    return @($out)
}

<#
.SYNOPSIS
The families_for_changed_path twin: conservative path -> family map.
.DESCRIPTION
The bash `case` arms are reproduced IN ORDER, because first-match-wins is what
keeps `docs/fm-test-portable-shards.md` out of the catch-all `docs/*` arm and
`tests/fm-test-run.test.sh` out of the generic `tests/*.test.sh` arm. Two
marker shapes leave this function alongside real family names, exactly as in
bash: `__script__:<basename>` selects one suite, and `__unmapped__:<path>` is
the fail-closed signal the caller turns into exit 2.
#>
function Get-FmTestRunFamilyForChangedPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )

    if ($Path -eq 'tests/fm-test-run.test.sh') { return @('pure-contract-unit') }
    if ($Path -eq 'tests/fm-backend-herdr-eventwait.test.py') {
        return @('real-herdr-gated', 'backend-dispatch')
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern 'tests/*.test.sh') {
        # A single test file change selects only that script via basename family
        # resolution in the caller; emit a marker family of __script__
        return @('__script__:' + (Get-FmTestRunBaseName $Path))
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-test-run.sh', 'bin/fm-test-isolation-proof.sh')) {
        return @('pure-contract-unit')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/backends/herdr*', 'bin/fm-herdr-lab.sh', 'tests/herdr-test-safety.sh')) {
        return @('real-herdr-gated', 'backend-dispatch', 'pure-contract-unit')
    }
    if ($Path -eq 'bin/fm-herdr-session-cleanup.sh') {
        return @('session-bootstrap', 'real-herdr-gated', 'backend-dispatch')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/backends/zellij*', 'tests/zellij-test-safety.sh')) {
        return @('zellij', 'backend-dispatch')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/backends/cmux*', 'tests/cmux-test-safety.sh')) {
        return @('cmux', 'backend-dispatch')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/backends/orca*', 'bin/backends/tmux.sh')) {
        return @('backend-dispatch', 'orca')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-backend.sh', 'bin/fm-backend-hometag-lib.sh')) {
        return @('backend-dispatch', 'real-herdr-gated')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-watch*', 'bin/fm-wake*', 'bin/fm-classify-lib.sh',
            'bin/fm-daemon*', 'bin/fm-turnend-guard*', 'bin/fm-guard.sh')) {
        return @('watcher-wake-lock')
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern 'bin/fm-afk*') {
        return @('afk', 'real-herdr-gated')
    }
    if ($Path -eq 'bin/fm-supervisor-target-lib.sh') {
        return @('watcher-wake-lock', 'real-herdr-gated', 'live-harness-optin', 'afk')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-startup-memory-budget.sh', 'bin/fm-startup-memory-budget-lib.sh')) {
        return @('secondmate', 'session-bootstrap')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-secondmate*', 'bin/fm-home-seed.sh', 'bin/fm-backlog-handoff.sh',
            'bin/fm-config-inherit-lib.sh', 'bin/fm-config-push.sh', 'bin/fm-shared*')) {
        return @('secondmate')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-session-start.sh', 'bin/fm-bootstrap.sh', 'bin/fm-fleet-sync.sh',
            'bin/fm-sessionstart-nudge.sh', 'bin/fm-tangle*', 'bin/fm-update.sh',
            'bin/fm-gate-refuse*', 'bin/fm-lock*', 'bin/fm-quota-axi-lib.sh')) {
        return @('session-bootstrap')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-pr-*', 'bin/fm-merge-local.sh', 'bin/fm-teardown.sh',
            'bin/fm-review-diff.sh', 'bin/fm-x-*', 'bin/fm-check*')) {
        return @('pr-forge')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-spawn.sh', 'bin/fm-send.sh', 'bin/fm-harness.sh',
            'bin/fm-peek.sh', 'bin/fm-composer*')) {
        return @('backend-dispatch', 'pure-contract-unit')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-bearings-snapshot.sh', 'bin/fm-fleet-snapshot.sh', 'bin/fm-fleet-view.sh')) {
        return @('snapshot-bearings')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-install-herdr.sh', 'bin/fm-install-treehouse.sh', 'bin/fm-herdr-ci-cleanup.sh')) {
        # Pin or cleanup changes also select the real-Herdr family so the required
        # lane's contract coverage re-runs.
        return @('pure-contract-unit', 'real-herdr-gated')
    }
    if (Test-FmTestRunGlobAny $Path @('bin/fm-lint.sh', 'bin/fm-install-shellcheck.sh', 'bin/fm-brief.sh',
            'bin/fm-ensure-agents-md.sh', 'bin/fm-crew-state.sh', 'bin/fm-decision-hold.sh',
            'bin/fm-supervision*', 'bin/fm-transition-lib.sh', 'bin/fm-tmux-lib.sh',
            'bin/fm-marker-lib.sh', 'bin/fm-operational-input.sh', 'bin/fm-tasks-axi-lib.sh',
            'bin/fm-vendor-auth-probe.sh', 'bin/fm-primary-scope-lib.sh', 'bin/fm-project-mode.sh',
            'bin/fm-promote.sh', 'bin/fm-ff-lib.sh', 'bin/fm-gotmp*', 'bin/*pretool*')) {
        return @('pure-contract-unit')
    }
    if ($Path -eq '.agents/skills/quota-array-dispatch/SKILL.md') {
        return @('pure-contract-unit', 'live-harness-optin')
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern '.agents/skills/*/SKILL.md') {
        return @('pure-contract-unit')
    }
    if (Test-FmTestRunGlobAny $Path @('.github/workflows/ci.yml', '.no-mistakes.yaml')) {
        return @('pure-contract-unit', 'real-herdr-gated')
    }
    if (Test-FmTestRunGlobAny $Path @('docs/fm-test-portable-shards.md', 'docs/fm-test-isolation-proof.md',
            'docs/fm-test-isolation-proof.json')) {
        return @('pure-contract-unit')
    }
    if (Test-FmTestRunGlobAny $Path @('.github/*', '.tasks.toml', 'AGENTS.md', 'CLAUDE.md', 'CONTRIBUTING.md',
            'docs/configuration.md', 'docs/supervision-protocols/*')) {
        return @('pure-contract-unit')
    }
    if (Test-FmTestRunGlobAny $Path @('tests/lib.sh', 'tests/*-helpers.sh')) {
        $refs = Get-FmTestRunFamilyForReference -Root $Root -Needle (Get-FmTestRunBaseName $Path)
        if ($null -eq $refs) { return @('__unmapped__:' + $Path) }
        return @($refs)
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern 'tests/fixtures/*/*') {
        # A fixture belongs to whichever suite reads its directory, found by the
        # same reference scan used for shared helpers. Keyed on the directory
        # rather than the file so adding a fixture selects the same suite.
        # A removed fixture directory has no consuming suite left to select.
        $fixtureRef = $Path.Substring('tests/fixtures/'.Length)
        $slash = $fixtureRef.IndexOf('/')
        if ($slash -ge 0) { $fixtureRef = $fixtureRef.Substring(0, $slash) }
        if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($Root, 'tests', 'fixtures', $fixtureRef))) {
            $refs = Get-FmTestRunFamilyForReference -Root $Root -Needle "fixtures/$fixtureRef"
            if ($null -eq $refs) { return @('__unmapped__:' + $Path) }
            return @($refs)
        }
        return @()
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern 'bin/*') {
        # A deleted script has no consuming suite left to select, the same rule
        # the fixture case above applies. Refusing on its absent mapping would
        # make every retirement branch unable to select its changed tests.
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($Root, (ConvertTo-FmNativePath $Path)))) {
            $refs = Get-FmTestRunFamilyForReference -Root $Root -Needle (Get-FmTestRunBaseName $Path)
            if ($null -eq $refs) { return @('__unmapped__:' + $Path) }
            return @($refs)
        }
        return @()
    }
    if (Test-FmTestRunGlob -Value $Path -Pattern 'tests/*') {
        return @('__unmapped__:' + $Path)
    }
    if (Test-FmTestRunGlobAny $Path @('README.md', 'LICENSE', 'assets/*', 'docs/*', '.gitignore')) {
        return @()
    }
    $refs = Get-FmTestRunFamilyForReference -Root $Root -Needle $Path
    if ($null -eq $refs) { return @('__unmapped__:' + $Path) }
    return @($refs)
}

<#
.SYNOPSIS
The select_changed twin.
#>
function Select-FmTestRunChanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$BaseRef
    )
    $root = $Context['Root']
    $verify = Invoke-FmTool 'git' @('-C', $root, 'rev-parse', '--verify', $BaseRef)
    if (-not $verify['Ok']) {
        throw [FmTestRunDie]::new("changed-file base ref not found: $BaseRef (pass --base <ref>)")
    }

    # The bash twin concatenates three git listings inside one process
    # substitution and ignores each one's exit status, so a repo with no HEAD or
    # no upstream simply contributes nothing rather than failing the selection.
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($argv in @(
            @('-C', $root, 'diff', '--name-only', "$BaseRef...HEAD"),
            @('-C', $root, 'diff', '--name-only', 'HEAD'),
            @('-C', $root, 'ls-files', '--others', '--exclude-standard'))) {
        $result = Invoke-FmTool 'git' $argv
        foreach ($line in ($result['StdOut'] -split "`n")) {
            if ($line -ne '') { $paths.Add($line) }
        }
    }

    $wantedFamilies = [System.Collections.Generic.List[string]]::new()
    $wantedScripts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        if ($path -eq '') { continue }
        foreach ($entry in @(Get-FmTestRunFamilyForChangedPath -Root $root -Path $path)) {
            if ($entry -eq '') { continue }
            if ($entry.StartsWith('__script__:')) {
                $wantedScripts.Add($entry.Substring('__script__:'.Length))
            } elseif ($entry.StartsWith('__unmapped__:')) {
                throw [FmTestRunDie]::new('no changed-test mapping for source path: ' + $entry.Substring('__unmapped__:'.Length))
            } else {
                $wantedFamilies.Add($entry)
            }
        }
    }

    # Dedup families, first-seen order (the bash twin's explicit seen_f loop).
    $uniqueFamilies = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $wantedFamilies) {
        $seen = $false
        foreach ($u in $uniqueFamilies) {
            if ([string]::Equals($u, $f, [System.StringComparison]::Ordinal)) { $seen = $true; break }
        }
        if (-not $seen) { $uniqueFamilies.Add($f) }
    }

    foreach ($f in $uniqueFamilies) {
        foreach ($s in (Get-FmTestRunRepoTest $root)) {
            if ($s -eq '') { continue }
            if ((Get-FmTestRunFamily (Get-FmTestRunBaseName $s)) -eq $f) {
                Add-FmTestRunScript -Context $Context -Path $s
            }
        }
    }

    foreach ($scriptName in $wantedScripts) {
        if ([System.IO.File]::Exists([System.IO.Path]::Combine($root, 'tests', $scriptName))) {
            Add-FmTestRunScript -Context $Context -Path "tests/$scriptName"
        }
    }

    if ($Context['Scripts'].Count -eq 0) {
        Write-FmTestRunLog "no tests selected for changes vs $BaseRef (map is conservative; use --all for the complete suite)"
    }
}

<#
.SYNOPSIS
The apply_exclude_families twin: drop scripts whose primary family is excluded.
#>
function Remove-FmTestRunExcludedFamily {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This filters an in-memory selection list on the hot path of a runner whose bash twin filters unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive CI lane.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)
    if ($Context['ExcludeFamilies'].Count -eq 0) { return }
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Context['Scripts']) {
        $fam = Get-FmTestRunFamily (Get-FmTestRunBaseName $s)
        $keep = $true
        foreach ($ex in $Context['ExcludeFamilies']) {
            if ([string]::Equals($fam, $ex, [System.StringComparison]::Ordinal)) { $keep = $false; break }
        }
        if ($keep) { $kept.Add($s) }
    }
    $Context['Scripts'] = $kept
}

# --- coverage guard ----------------------------------------------------------

<#
.SYNOPSIS
The run_coverage_guard twin. $true = the FM_TEST_COVERAGE ok line, $false = a
refusal already reported on stderr.
.DESCRIPTION
Five invariants, checked in the bash order because the first failure is the one
a caller sees:
  1. the two portable parallel shards share no script;
  2. their union is exactly the proven-isolated set;
  3. the CI serial shards share no script and their union is exactly the
     portable-serial lane - so no runner repeats work and no script is silently
     left out of the required lane;
  4. shards, portable-serial and the Herdr lane are pairwise disjoint and
     contain no duplicate;
  5. their union is exactly tests/*.test.sh.
Then, when an isolation-proof twin exists, the embedded proven set must equal
what that harness lists.

The bash twin gates that last check on `[ -x ]`. This one asks
Invoke-FmScript's own question - is there a .ps1 or a .sh to run - because
during the transition either spelling is the harness, and an absent harness
must skip the check in both worlds identically.

ONE PLACE THIS TWIN DELIBERATELY SUCCEEDS WHERE THE BASH TWIN FAILS, on this
host and on any host whose locale is not C. bin/fm-test-run.sh sorts the guard's
files with `LC_ALL=C sort` but invokes `comm` WITHOUT that pin, so comm judges
its own inputs unsorted, warns, and RETURNS NON-ZERO - and the three
`comm -12 ... >"$tmp/overlap"` calls are not guarded by `|| true`, so `set -e`
kills the runner right there. Measured on the real tests/ directory here: the
bash guard exits 1 after 28 minutes having printed no diagnostic at all, and
`tests/fm-backend.test.sh` vs `tests/fm-backend-cmux-smoke.test.sh` is enough to
trigger it - both long-standing files, and the failure reproduces with every
recently added test file removed, so it is not caused by the port.

This module computes the same set algebra in-process with ordinal comparisons,
so it reaches the real verdict and reports it. That is not a liberty taken with
the contract: the guard's ANSWER is unchanged (the overlaps really are empty),
only the bash twin's ability to finish computing it differs. Repairing the bash
side belongs to a change that owns bin/fm-test-run.sh, and until then this twin
must not be "corrected" to fail alongside it.
#>
function Test-FmTestRunCoverage {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)

    $root = $Context['Root']
    $all = @(Get-FmTestRunSortedUnique (Get-FmTestRunRepoTest $root))
    $proven = @(Get-FmTestRunSortedUnique (Get-FmTestRunProvenIsolated))
    $s1 = @(Get-FmTestRunSortedUnique (Get-FmTestRunPortableShard 1))
    $s2 = @(Get-FmTestRunSortedUnique (Get-FmTestRunPortableShard 2))

    $shardDups = @(Get-FmTestRunSetDuplicate (Get-FmTestRunSorted (@($s1) + @($s2))))
    if ($shardDups.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: portable parallel shards share scripts:'
        foreach ($d in $shardDups) { Write-FmErr $d }
        return $false
    }
    $shardsUnion = @(Get-FmTestRunSortedUnique (@($s1) + @($s2)))
    $missing = @(Get-FmTestRunSetDiff $proven $shardsUnion)
    $extra = @(Get-FmTestRunSetDiff $shardsUnion $proven)
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: portable shards must equal the proven-isolated set'
        if ($missing.Count -gt 0) {
            Write-FmTestRunLog 'missing from shards:'
            foreach ($m in $missing) { Write-FmErr $m }
        }
        if ($extra.Count -gt 0) {
            Write-FmTestRunLog 'extra beyond proven:'
            foreach ($e in $extra) { Write-FmErr $e }
        }
        return $false
    }

    # Serial (whole lane and each CI shard) + Herdr lane listings without
    # disturbing a caller's selection.
    $savedScripts = $Context['Scripts']
    $Context['Scripts'] = [System.Collections.Generic.List[string]]::new()
    Select-FmTestRunLane -Context $Context -Lane 'portable-serial'
    $serial = @(Get-FmTestRunSortedUnique $Context['Scripts'])
    $serialShardsRaw = [System.Collections.Generic.List[string]]::new()
    for ($shard = 1; $shard -le $script:FmTestRunPortableSerialShards; $shard++) {
        $Context['Scripts'] = [System.Collections.Generic.List[string]]::new()
        # An EMPTY shard never reaches the report below, because the twin's
        # select_lane dies with "selected no tests" (exit 2) first. The check is
        # kept anyway, exactly as the twin keeps it, so the two guards stay the
        # same program rather than one of them quietly losing an invariant.
        Select-FmTestRunLane -Context $Context `
            -Lane ("portable-serial-{0}of{1}" -f $shard, $script:FmTestRunPortableSerialShards)
        if ($Context['Scripts'].Count -eq 0) {
            Write-FmTestRunLog ("coverage guard: portable serial shard {0} of {1} is empty" -f
                $shard, $script:FmTestRunPortableSerialShards)
            $Context['Scripts'] = $savedScripts
            return $false
        }
        foreach ($s in $Context['Scripts']) { $serialShardsRaw.Add($s) }
    }
    $Context['Scripts'] = [System.Collections.Generic.List[string]]::new()
    Select-FmTestRunFamily -Context $Context -Family 'real-herdr-gated'
    $herdr = @(Get-FmTestRunSortedUnique $Context['Scripts'])
    $Context['Scripts'] = $savedScripts

    # Every serial script runs in exactly one CI shard: no duplicate work across
    # runners, and no script silently left out of the required lane.
    $serialShardDups = @(Get-FmTestRunSetDuplicate (Get-FmTestRunSorted $serialShardsRaw))
    if ($serialShardDups.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: portable serial shards share scripts:'
        foreach ($d in $serialShardDups) { Write-FmErr $d }
        return $false
    }
    $serialShards = @(Get-FmTestRunSortedUnique $serialShardsRaw)
    $missing = @(Get-FmTestRunSetDiff $serial $serialShards)
    $extra = @(Get-FmTestRunSetDiff $serialShards $serial)
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: portable serial shards must equal the portable serial lane'
        if ($missing.Count -gt 0) {
            Write-FmTestRunLog 'missing from serial shards:'
            foreach ($m in $missing) { Write-FmErr $m }
        }
        if ($extra.Count -gt 0) {
            Write-FmTestRunLog 'extra beyond serial lane:'
            foreach ($e in $extra) { Write-FmErr $e }
        }
        return $false
    }

    foreach ($pair in @(
            @{ A = 'shards_union'; B = 'serial'; Left = $shardsUnion; Right = $serial },
            @{ A = 'shards_union'; B = 'herdr'; Left = $shardsUnion; Right = $herdr },
            @{ A = 'serial'; B = 'herdr'; Left = $serial; Right = $herdr })) {
        $overlap = @(Get-FmTestRunSetIntersect $pair['Left'] $pair['Right'])
        if ($overlap.Count -gt 0) {
            Write-FmTestRunLog ("coverage guard: overlap between {0} and {1}:" -f $pair['A'], $pair['B'])
            foreach ($o in $overlap) { Write-FmErr $o }
            return $false
        }
    }

    $unionRaw = @(Get-FmTestRunSorted (@($shardsUnion) + @($serial) + @($herdr)))
    $unionDups = @(Get-FmTestRunSetDuplicate $unionRaw)
    if ($unionDups.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: duplicate scripts across lanes:'
        foreach ($d in $unionDups) { Write-FmErr $d }
        return $false
    }
    $union = @(Get-FmTestRunSortedUnique $unionRaw)
    $missing = @(Get-FmTestRunSetDiff $all $union)
    $extra = @(Get-FmTestRunSetDiff $union $all)
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        Write-FmTestRunLog 'coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh'
        if ($missing.Count -gt 0) {
            Write-FmTestRunLog 'missing from union:'
            foreach ($m in $missing) { Write-FmErr $m }
        }
        if ($extra.Count -gt 0) {
            Write-FmTestRunLog 'extra beyond inventory:'
            foreach ($e in $extra) { Write-FmErr $e }
        }
        return $false
    }

    $binDir = [System.IO.Path]::Combine($root, 'bin')
    $proofPs = [System.IO.Path]::Combine($binDir, 'fm-test-isolation-proof.ps1')
    $proofSh = [System.IO.Path]::Combine($binDir, 'fm-test-isolation-proof.sh')
    if ([System.IO.File]::Exists($proofPs) -or [System.IO.File]::Exists($proofSh)) {
        $listed = Invoke-FmScript 'fm-test-isolation-proof' @('--list') -BinDir $binDir -WorkingDirectory $root
        $proofList = @(Get-FmTestRunSortedUnique (@($listed['StdOut'] -split "`n") | Where-Object { $_ -ne '' }))
        $sameLength = ($proofList.Count -eq $proven.Count)
        $same = $sameLength
        if ($same) {
            for ($i = 0; $i -lt $proven.Count; $i++) {
                if (-not [string]::Equals($proven[$i], $proofList[$i], [System.StringComparison]::Ordinal)) { $same = $false; break }
            }
        }
        if (-not $same) {
            Write-FmTestRunLog 'coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list'
            foreach ($line in (Get-FmTestRunSetSymmetric $proven $proofList)) { Write-FmErr $line }
            return $false
        }
    }

    Write-FmOut ("FM_TEST_COVERAGE ok total={0} parallel={1} serial={2} serial_shards={3} herdr={4}" -f
        $all.Count, $shardsUnion.Count, $serial.Count, $script:FmTestRunPortableSerialShards, $herdr.Count)
    return $true
}

# --- JSON --------------------------------------------------------------------

<#
.SYNOPSIS
Serialize like python's `json.dumps(obj, indent=2, sort_keys=True)`.
.DESCRIPTION
Not ConvertTo-Json, which sorts nothing, escapes differently, and renders an
empty collection on its own lines. The timing artifacts are durable records
that both language trees write and read (contract 2), and CI diffs them, so the
bytes have to match the twin's exactly:
  - keys sorted ordinally, two-space indent, ": " between key and value;
  - `{}` / `[]` for an empty map or list, with no inner newline;
  - ensure_ascii escaping: every non-ASCII character becomes \uXXXX, and the
    short forms \" \\ \b \f \n \r \t are used where python uses them.
Doubles use round-trip formatting; the runner's own artifacts contain only
integers, strings and booleans, so that arm exists for foreign lane files.
#>
function ConvertTo-FmTestRunJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value,
        [Parameter(Position = 1)][int]$Depth = 0
    )
    $pad = ' ' * (2 * $Depth)
    $padInner = ' ' * (2 * ($Depth + 1))

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-FmTestRunJsonString $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [System.Numerics.BigInteger]) {
        return [string]$Value
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $Value.Keys) { $keys.Add([string]$k) }
        if ($keys.Count -eq 0) { return '{}' }
        $keys.Sort([System.StringComparer]::Ordinal)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $keys) {
            $parts.Add($padInner + (ConvertTo-FmTestRunJsonString $k) + ': ' + (ConvertTo-FmTestRunJson $Value[$k] ($Depth + 1)))
        }
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            $parts.Add($padInner + (ConvertTo-FmTestRunJson $item ($Depth + 1)))
        }
        if ($parts.Count -eq 0) { return '[]' }
        return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
    }
    return (ConvertTo-FmTestRunJsonString ([string]$Value))
}

function ConvertTo-FmTestRunJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        switch ($ch) {
            '"' { [void]$sb.Append('\"'); continue }
            '\' { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ($code -lt 0x20 -or $code -gt 0x7E) {
                    [void]$sb.Append('\u').Append($code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture))
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

<#
.SYNOPSIS
Parse JSON with python's `json.load` fidelity.
.DESCRIPTION
NOT ConvertFrom-Json, which COERCES any string that looks like a date into a
[DateTime]. Measured here: a lane artifact's "2026-07-22T00:01:00Z" came back
as a DateTime and was re-serialized as "07/22/2026 00:01:00" - a corrupted
timestamp in an aggregate document that is supposed to be byte-identical to the
bash twin's. python's json.load has no such behavior, so neither may this.

System.Text.Json has no coercion at all: strings stay strings, integral numbers
become Int64 and fractional ones Double (python's int/float split), and objects
keep their source order. Objects become ordered dictionaries so a caller can ask
.Contains() exactly as it would of the -AsHashtable shape.
#>
function ConvertFrom-FmTestRunJson {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Json)
    $doc = [System.Text.Json.JsonDocument]::Parse($Json)
    try {
        return (Convert-FmTestRunJsonElement $doc.RootElement)
    } finally {
        $doc.Dispose()
    }
}

function Convert-FmTestRunJsonElement {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)]$Element)
    $kind = $Element.ValueKind.ToString()
    if ($kind -eq 'Object') {
        $map = [ordered]@{}
        foreach ($property in $Element.EnumerateObject()) {
            $map[$property.Name] = Convert-FmTestRunJsonElement $property.Value
        }
        return $map
    }
    if ($kind -eq 'Array') {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Element.EnumerateArray()) {
            $list.Add((Convert-FmTestRunJsonElement $item))
        }
        # The unary comma is load-bearing: without it PowerShell unrolls the
        # array on return and a one-element list arrives as a bare scalar.
        return , @($list)
    }
    if ($kind -eq 'String') { return $Element.GetString() }
    if ($kind -eq 'True') { return $true }
    if ($kind -eq 'False') { return $false }
    if ($kind -eq 'Null') { return $null }
    # Number: integral values stay integral, matching python's int/float split.
    $int64 = 0L
    if ($Element.TryGetInt64([ref]$int64)) { return $int64 }
    return $Element.GetDouble()
}

# python's `int(x or 0)`: absent, null, empty and 0 all collapse to 0.
function ConvertTo-FmTestRunInt {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Position = 0)][AllowNull()]$Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [bool]) { if ($Value) { return 1 } else { return 0 } }
    $text = [string]$Value
    if ($text -eq '') { return 0 }
    return [long]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-FmTestRunDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is the mkdir -p a bash twin performs unconditionally before writing an artifact; a confirmation surface would diverge from the twin and could stall a non-interactive CI lane.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    if (-not [System.IO.Directory]::Exists($Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}

<#
.SYNOPSIS
The write_json_artifact twin: the per-run timing artifact.
#>
function Write-FmTestRunTimingJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This writes the artifact its bash twin writes unconditionally at the same point in the run; a confirmation surface would diverge from the twin and could stall a non-interactive CI lane.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Started,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Finished,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory)][long]$Total,
        [Parameter(Mandatory)][long]$Failed,
        [Parameter(Mandatory)][long]$Skipped,
        [Parameter(Mandatory)][long]$Duration,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Selection,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Records,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Families
    )
    $scripts = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($Records)) {
        if ($line -eq '') { continue }
        $f = @($line.Split("`t"))
        if ($f.Count -ne 6) { throw [FmTestRunDie]::new("malformed timing record: $line") }
        $scripts.Add([ordered]@{
                path               = $f[0]
                family             = $f[1]
                expected_gate_skip = $f[2]
                duration_ms        = [long]$f[4]
                exit               = [long]$f[3]
                gate_skip          = ($f[5] -eq 'true')
            })
    }
    # Named familyRows, not families: PowerShell variable names are
    # case-INSENSITIVE, so `$families` here would silently overwrite the
    # $Families parameter and every family row would be dropped.
    $familyRows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($Families)) {
        if ($line -eq '') { continue }
        $f = @($line.Split("`t"))
        if ($f.Count -ne 4) { throw [FmTestRunDie]::new("malformed family record: $line") }
        $familyRows.Add([ordered]@{
                name        = $f[0]
                count       = [long]$f[1]
                duration_ms = [long]$f[2]
                failed      = [long]$f[3]
            })
    }
    $doc = [ordered]@{
        run_id     = $RunId
        started_at = $Started
        finished_at = $Finished
        selection  = $Selection
        summary    = [ordered]@{
            total        = $Total
            failed       = $Failed
            skipped_gate = $Skipped
            duration_ms  = $Duration
        }
        scripts    = $scripts
        families   = $familyRows
    }
    Set-FmFileText -Path $Path -Text ((ConvertTo-FmTestRunJson $doc 0) + "`n") -NoNewline
}

<#
.SYNOPSIS
The aggregate_timing_json twin: merge lane artifacts into one document.
#>
function Merge-FmTestRunTimingJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$OutPath,
        [Parameter(Mandatory, Position = 1)][AllowNull()][AllowEmptyCollection()][string[]]$InputPath,
        [Parameter(Position = 2)][AllowEmptyString()][string]$Root = ''
    )
    $inputs = @($InputPath)
    if ($inputs.Count -eq 0) {
        throw [FmTestRunDie]::new('--aggregate-json requires at least one input timing JSON')
    }
    $lanes = [System.Collections.Generic.List[object]]::new()
    $allScripts = [System.Collections.Generic.List[object]]::new()
    $failed = 0L; $skipped = 0L; $total = 0L; $wallMs = 0L

    foreach ($path in $inputs) {
        # The lane record keeps the path AS GIVEN. The bash twin writes
        # `"path": str(path)` - the argv string, not a resolved one - so
        # recording a resolved path here would spell a relative input one way in
        # bash and another way in PowerShell. (One residue remains on Windows
        # and is not worth chasing: python's str(Path(p)) flips '/' to '\', and
        # bash hands an ABSOLUTE posix argument to native python through MSYS
        # translation, so both are artifacts of the twin's interpreter rather
        # than of the runner. A bare or relative input avoids both.)
        $readPath = if ($Root -ne '') { Resolve-FmTestRunPath -Root $Root -Path $path } else { $path }
        $doc = ConvertFrom-FmTestRunJson (Get-FmFileText $readPath)
        $summary = if ($doc.Contains('summary') -and $null -ne $doc['summary']) { $doc['summary'] } else { [ordered]@{} }
        $runId = if ($doc.Contains('run_id')) { $doc['run_id'] } else { $null }
        $selection = if ($doc.Contains('selection')) { $doc['selection'] } else { $null }
        $lanes.Add([ordered]@{
                path        = $path
                run_id      = $runId
                selection   = $selection
                started_at  = $(if ($doc.Contains('started_at')) { $doc['started_at'] } else { $null })
                finished_at = $(if ($doc.Contains('finished_at')) { $doc['finished_at'] } else { $null })
                summary     = $summary
            })
        $total += ConvertTo-FmTestRunInt $(if ($summary.Contains('total')) { $summary['total'] } else { $null })
        $failed += ConvertTo-FmTestRunInt $(if ($summary.Contains('failed')) { $summary['failed'] } else { $null })
        $skipped += ConvertTo-FmTestRunInt $(if ($summary.Contains('skipped_gate')) { $summary['skipped_gate'] } else { $null })
        $laneMs = ConvertTo-FmTestRunInt $(if ($summary.Contains('duration_ms')) { $summary['duration_ms'] } else { $null })
        if ($laneMs -gt $wallMs) { $wallMs = $laneMs }
        $docScripts = if ($doc.Contains('scripts') -and $null -ne $doc['scripts']) { @($doc['scripts']) } else { @() }
        foreach ($s in $docScripts) {
            $row = [ordered]@{}
            foreach ($k in $s.Keys) { $row[[string]$k] = $s[$k] }
            $row['lane_selection'] = $selection
            $row['lane_run_id'] = $runId
            $allScripts.Add($row)
        }
    }

    # python: sort(key=lambda s: (-int(duration_ms or 0), path or "")), a STABLE
    # sort with an ORDINAL string tiebreak. Sort-Object gives neither: it is not
    # stable, and its string comparison is culture-aware. So each row gets one
    # composite ordinal key - duration descending, then path, then input order -
    # and the input-order component makes every key unique, which delivers
    # python's stability without needing a stable sort primitive at all.
    $keys = [System.Collections.Generic.List[string]]::new()
    $byKey = @{}
    $index = 0
    foreach ($s in $allScripts) {
        $rowMs = ConvertTo-FmTestRunInt $(if ($s.Contains('duration_ms')) { $s['duration_ms'] } else { $null })
        $rowPath = [string]$(if ($s.Contains('path') -and $null -ne $s['path']) { $s['path'] } else { '' })
        $key = ('{0:D19}' -f ([long]::MaxValue - $rowMs)) + "`t" + $rowPath + "`t" + ('{0:D9}' -f $index)
        $keys.Add($key)
        $byKey[$key] = $s
        $index++
    }
    $keys.Sort([System.StringComparer]::Ordinal)
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $keys) { $keyed.Add($byKey[$k]) }

    $slowest = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt [Math]::Min(15, $keyed.Count); $i++) { $slowest.Add($keyed[$i]) }

    $agg = [ordered]@{
        kind    = 'aggregate'
        lanes   = $lanes
        summary = [ordered]@{
            lanes                      = [long]$lanes.Count
            total                      = $total
            failed                     = $failed
            skipped_gate               = $skipped
            critical_path_duration_ms  = $wallMs
        }
        scripts = @($keyed)
        slowest = @($slowest)
    }
    New-FmTestRunDirectory ([System.IO.Path]::GetDirectoryName($OutPath))
    Set-FmFileText -Path $OutPath -Text ((ConvertTo-FmTestRunJson $agg 0) + "`n") -NoNewline
    Write-FmOut ("FM_TEST_AGGREGATE lanes={0} total={1} failed={2} skipped_gate={3} critical_path_duration_ms={4}" -f
        $lanes.Count, $total, $failed, $skipped, $wallMs)
}

# --- gate-skip detection -----------------------------------------------------

<#
.SYNOPSIS
The detect_gate_skip twin: is the first non-blank output line a `skip:` line?
.DESCRIPTION
bash uses `awk 'NF { print; exit }'`, and NF is zero for a line of nothing but
whitespace - so a leading blank OR whitespace-only line is skipped, and the
first line with any field decides.
#>
function Test-FmTestRunGateSkip {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Output)
    if ([string]::IsNullOrEmpty($Output)) { return $false }
    foreach ($line in ($Output -replace "`r`n", "`n" -split "`n")) {
        if ($line.Trim() -eq '') { continue }
        return $line.StartsWith('skip:')
    }
    return $false
}

<#
.SYNOPSIS
The detect_gate_skip_token twin: does any line contain "skip: <token>"?
#>
function Test-FmTestRunGateSkipToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Output,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Token
    )
    if ([string]::IsNullOrEmpty($Token)) { return $false }
    if ([string]::IsNullOrEmpty($Output)) { return $false }
    return ($Output.IndexOf("skip: $Token", [System.StringComparison]::Ordinal) -ge 0)
}

# --- worker-root isolation on an inert-chmod filesystem ----------------------

$script:FmTestRunModeInertDir = $null
$script:FmTestRunModeInertVerdict = $null

<#
.SYNOPSIS
The mode a Git Bash `stat -c %a` would report for a path.
.DESCRIPTION
There is no POSIX mode on NTFS and .NET refuses File.GetUnixFileMode on
Windows, but the gate compares against what the BASH twin sees, and a
noacl-mounted Git Bash derives that from Windows attributes: 0444 always, +0200
unless FILE_ATTRIBUTE_READONLY, +0111 for a directory. Only directories are
ever asked about here, so this is the directory arm of the rule that
bin/fm-pr-lib.psm1 documents in full. Off Windows the platform has real modes
and .NET answers directly.
#>
function Get-FmTestRunDirMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    # Spelled in decimal because this PowerShell has no 0o literal (verified:
    # `0o755` is a parse error on 7.6.4). 365 = 0555, 128 = 0200, 511 = 0777.
    $native = ConvertTo-FmNativePath $Path
    try {
        if (Test-FmWindows) {
            $attrs = [System.IO.File]::GetAttributes($native)
            $mode = 365
            if (-not ($attrs -band [System.IO.FileAttributes]::ReadOnly)) { $mode = $mode -bor 128 }
            return [System.Convert]::ToString($mode, 8)
        }
        $unix = (Get-Item -LiteralPath $native -Force).UnixFileMode
        return ([System.Convert]::ToString(([int]$unix -band 511), 8))
    } catch {
        return 'unknown'
    }
}

<#
.SYNOPSIS
Is chmod on this directory accepted but provably ineffective?
.DESCRIPTION
The twin of fm_pr_mode_enforcement_inert in bin/fm-pr-lib.sh, duplicated here
for the reason that lib duplicates it into bin/fm-x-lib.sh: each owner stays
self-contained, and bin/fm-test-run.sh has no source edges to inherit it
through. Creates a private child, applies the strictest change the platform
permits, reads the mode back, and concludes INERT unless the change stuck.
Runs only AFTER a mode gate has already failed, so a mode-honoring host keeps
exact behavior and pays nothing. Memoized per directory.
#>
function Test-FmTestRunModeEnforcementInert {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $false }
    $native = ConvertTo-FmNativePath $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return $false }
    if ($null -ne $script:FmTestRunModeInertDir -and $null -ne $script:FmTestRunModeInertVerdict -and
        [string]::Equals($native, $script:FmTestRunModeInertDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $script:FmTestRunModeInertVerdict
    }
    $script:FmTestRunModeInertDir = $native
    $script:FmTestRunModeInertVerdict = $false

    $probe = [System.IO.Path]::Combine($native, '.fm-test-run-modeprobe.' + [System.IO.Path]::GetRandomFileName())
    try {
        [void][System.IO.Directory]::CreateDirectory($probe)
        if (Test-FmWindows) {
            # The MSYS chmod twin on a noacl mount: only the owner-write bit is
            # expressible, and it maps onto FILE_ATTRIBUTE_READONLY. Doing
            # exactly that is what makes this probe answer the way the bash
            # probe answers on the same directory.
            $item = Get-Item -LiteralPath $probe -Force
            $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        } else {
            (Get-Item -LiteralPath $probe -Force).UnixFileMode =
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
                [System.IO.UnixFileMode]::UserExecute
        }
        $mode = Get-FmTestRunDirMode $probe
        $script:FmTestRunModeInertVerdict = ($mode -ne '700')
    } catch {
        # A directory whose probe could not be created is remembered as NOT
        # inert, the same fail-safe direction the bash twin takes.
        $script:FmTestRunModeInertVerdict = $false
    } finally {
        try {
            if ([System.IO.Directory]::Exists($probe)) {
                if (Test-FmWindows) {
                    $item = Get-Item -LiteralPath $probe -Force
                    $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
                [System.IO.Directory]::Delete($probe, $true)
            }
        } catch { $null = $_ }
    }
    return $script:FmTestRunModeInertVerdict
}

<#
.SYNOPSIS
The owner of a path, in whatever identity vocabulary this platform uses.
.DESCRIPTION
The `stat -c %u` twin of fm_pr_file_owner. On Windows the comparable identity
is the owner SID, which is what Get-FmTestRunCurrentOwner also returns, so the
two are compared in one vocabulary. Off Windows this arm is unreachable in
practice - chmod works there, so the mode gate never falls through to
ownership - and it defers to `stat` exactly as the bash twin does rather than
inventing a second answer. An unreadable owner returns '', which fails the
comparison and refuses the artifact: the safe direction.
#>
function Get-FmTestRunPathOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        if (Test-FmWindows) {
            $acl = Get-Acl -LiteralPath $native
            $sid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
            return [string]$sid.Value
        }
        $flag = if ($IsMacOS) { '-f' } else { '-c' }
        $fmt = if ($IsMacOS) { '%u' } else { '%u' }
        $result = Invoke-FmTool 'stat' @($flag, $fmt, $native)
        if (-not $result['Ok']) { return '' }
        return ([string]$result['StdOut']).Trim()
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
The `id -u` twin: this process's own identity, comparable to a path's owner.
#>
function Get-FmTestRunCurrentOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        if (Test-FmWindows) {
            return [string]([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
        $result = Invoke-FmTool 'id' @('-u')
        if (-not $result['Ok']) { return '' }
        return ([string]$result['StdOut']).Trim()
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
Is this worker root privately owned - by mode where that is expressible, and by
ownership where chmod is provably inert?
.DESCRIPTION
The bash twin asserts `stat -c %a` reads 700 and calls anything else an
isolation failure. That gate is unsatisfiable on a noacl mount, so this reuses
the tree's existing answer to exactly this situation: check the mode first, and
only when it fails AND the filesystem is provably inert, accept the directory
on ownership instead. Returns the verdict plus the mode actually observed, so
the caller can report the same "worker root mode is <mode>" diagnostic the bash
twin reports.
#>
function Test-FmTestRunWorkerRoot {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $mode = Get-FmTestRunDirMode $Path
    if ($mode -eq '700' -or $mode -eq '0700') {
        return @{ Ok = $true; Mode = $mode; Basis = 'mode' }
    }
    $parent = [System.IO.Path]::GetDirectoryName((ConvertTo-FmNativePath $Path))
    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    if (Test-FmTestRunModeEnforcementInert $parent) {
        $owner = Get-FmTestRunPathOwner $Path
        $me = Get-FmTestRunCurrentOwner
        if ($owner -ne '' -and [string]::Equals($owner, $me, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ Ok = $true; Mode = $mode; Basis = 'ownership' }
        }
    }
    return @{ Ok = $false; Mode = $mode; Basis = 'mode' }
}

# --- executing one test script -----------------------------------------------

<#
.SYNOPSIS
Start one test script and return a worker record with its live streams.
.DESCRIPTION
A `.ps1` runs under the pwsh running this module, so a converted suite inherits
this exact interpreter; anything else runs under Git Bash, located through
fm-common's Get-FmBash rather than assumed on PATH. Both streams are redirected
and their first ReadLineAsync is already in flight when this returns, so a
caller holding several workers can pump them all without any of them blocking
on a full pipe buffer.

A missing bash is reported as a completed worker with exit 127 rather than an
exception: the bash twin's own failure to run a script is an ordinary non-zero
result that the run accounts for, not a crash of the runner.
#>
function Start-FmTestRunChild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This starts the test process its bash twin starts unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive CI lane.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ScriptPath,
        [Parameter(Mandatory, Position = 1)][string]$WorkingDirectory,
        [Parameter(Position = 2)][AllowNull()][hashtable]$Environment
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($ScriptPath.EndsWith('.ps1')) {
        $self = (Get-Process -Id $PID).Path
        if (-not $self) { $self = 'pwsh' }
        $psi.FileName = $self
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add((Resolve-FmTestRunPath -Root $WorkingDirectory -Path $ScriptPath))
    } else {
        $bash = Get-FmBash
        if (-not $bash) {
            return @{
                Proc = $null; Out = $null; Err = $null
                Buffer = [System.Text.StringBuilder]::new("fm-test-run: no bash available to run $ScriptPath`n")
                ExitCode = 127; Done = $true
            }
        }
        $psi.FileName = $bash
        # Bash receives a POSIX path: it cannot be relied on to accept a Windows
        # drive path as a script argument.
        $psi.ArgumentList.Add((ConvertTo-FmPosixPath (Resolve-FmTestRunPath -Root $WorkingDirectory -Path $ScriptPath)))
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = ConvertTo-FmNativePath $WorkingDirectory
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $value = $Environment[$key]
            if ($null -eq $value) { [void]$psi.Environment.Remove([string]$key) }
            else { $psi.Environment[[string]$key] = [string]$value }
        }
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    return @{
        Proc     = $proc
        Out      = $proc.StandardOutput.ReadLineAsync()
        Err      = $proc.StandardError.ReadLineAsync()
        Buffer   = [System.Text.StringBuilder]::new()
        ExitCode = -1
        Done     = $false
    }
}

<#
.SYNOPSIS
Pump every live worker once: wait for the next line from any of them.
.DESCRIPTION
This is what makes --jobs genuinely concurrent WITHOUT a runspace per worker.
Every worker's two pending ReadLineAsync tasks go into one array and
Task.WaitAny returns whichever produced a line first, so N children run at
once, none stalls on a full pipe, and each worker's own buffer stays in arrival
order. -Stream echoes each line as it arrives, which is what makes a serial
run's output live the way `| tee` makes the bash twin's live.

A worker whose streams have both closed is marked Done after its process is
reaped, so the caller can collect it and refill the slot.
#>
function Step-FmTestRunChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.Generic.List[hashtable]]$Worker,
        [switch]$Stream
    )
    $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    $owners = [System.Collections.Generic.List[hashtable]]::new()
    $isOut = [System.Collections.Generic.List[bool]]::new()
    foreach ($w in $Worker) {
        if ($w['Done']) { continue }
        if ($null -ne $w['Out']) { $tasks.Add($w['Out']); $owners.Add($w); $isOut.Add($true) }
        if ($null -ne $w['Err']) { $tasks.Add($w['Err']); $owners.Add($w); $isOut.Add($false) }
    }
    if ($tasks.Count -eq 0) {
        # Every live worker has closed both streams; reap them.
        foreach ($w in $Worker) {
            if ($w['Done']) { continue }
            $w['Proc'].WaitForExit()
            $w['ExitCode'] = $w['Proc'].ExitCode
            $w['Proc'].Dispose()
            $w['Proc'] = $null
            $w['Done'] = $true
        }
        return
    }
    $index = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$tasks.ToArray())
    $w = $owners[$index]
    $out = $isOut[$index]
    $line = ([System.Threading.Tasks.Task[string]]$tasks[$index]).GetAwaiter().GetResult()
    if ($null -eq $line) {
        if ($out) { $w['Out'] = $null } else { $w['Err'] = $null }
        if ($null -eq $w['Out'] -and $null -eq $w['Err']) {
            $w['Proc'].WaitForExit()
            $w['ExitCode'] = $w['Proc'].ExitCode
            $w['Proc'].Dispose()
            $w['Proc'] = $null
            $w['Done'] = $true
        }
        return
    }
    [void]$w['Buffer'].Append($line).Append("`n")
    if ($Stream) { Write-FmOut $line }
    if ($out) { $w['Out'] = $w['Proc'].StandardOutput.ReadLineAsync() }
    else { $w['Err'] = $w['Proc'].StandardError.ReadLineAsync() }
}

<#
.SYNOPSIS
A worker's merged output, with any CR stripped.
.DESCRIPTION
A CR can only come from a child that wrote CRLF itself. The markers and both
gate-skip gates are parsed by line, and a stray CR would fail a `^skip:` test
in bash but not here, so it is removed at the boundary rather than everywhere
after.
#>
function Get-FmTestRunChildOutput {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Worker)
    return ($Worker['Buffer'].ToString() -replace "`r", '')
}

<#
.SYNOPSIS
Run one test script to completion; the serial path's whole mechanism.
#>
function Invoke-FmTestRunScriptProcess {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ScriptPath,
        [Parameter(Mandatory, Position = 1)][string]$WorkingDirectory,
        [Parameter(Position = 2)][AllowNull()][hashtable]$Environment,
        [switch]$Stream
    )
    $worker = Start-FmTestRunChild -ScriptPath $ScriptPath -WorkingDirectory $WorkingDirectory -Environment $Environment
    $list = [System.Collections.Generic.List[hashtable]]::new()
    $list.Add($worker)
    while (-not $worker['Done']) { Step-FmTestRunChild -Worker $list -Stream:$Stream }
    return @{ ExitCode = [int]$worker['ExitCode']; Output = (Get-FmTestRunChildOutput $worker) }
}

# --- accounting --------------------------------------------------------------

<#
.SYNOPSIS
The family_bump twin: add one script's duration and failure to its family row.
#>
function Add-FmTestRunFamilyTotal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][string]$Family,
        [Parameter(Mandatory, Position = 2)][long]$Duration,
        [Parameter(Mandatory, Position = 3)][long]$FailedDelta
    )
    $rows = $Context['FamilyRows']
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ([string]::Equals($rows[$i]['Name'], $Family, [System.StringComparison]::Ordinal)) {
            $rows[$i]['Count'] = [long]$rows[$i]['Count'] + 1
            $rows[$i]['Duration'] = [long]$rows[$i]['Duration'] + $Duration
            $rows[$i]['Failed'] = [long]$rows[$i]['Failed'] + $FailedDelta
            return
        }
    }
    $rows.Add(@{ Name = $Family; Count = [long]1; Duration = $Duration; Failed = $FailedDelta })
}

<#
.SYNOPSIS
The record_script_result twin: print FM_TEST_END and account for one script.
#>
function Register-FmTestRunResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][long]$Duration,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$EndIso
    )
    $family = Get-FmTestRunFamily (Get-FmTestRunBaseName $ScriptPath)
    $expected = Get-FmTestRunExpectedGateSkip $family
    $rc = $ExitCode

    $token = $Context['FailOnGateSkip']
    if ($token -ne '' -and (Test-FmTestRunGateSkipToken $Output $token)) {
        Write-FmTestRunLog "required gate skip token seen in ${ScriptPath}: skip: $token"
        $rc = 1
    }

    $gateSkip = 'false'
    if ($rc -eq 0 -and (Test-FmTestRunGateSkip $Output)) {
        $gateSkip = 'true'
        $Context['SkippedGate'] = [long]$Context['SkippedGate'] + 1
    }

    Write-FmOut ("FM_TEST_END {0} {1} exit={2} duration_ms={3} gate_skip={4}" -f
        $EndIso, $ScriptPath, $rc, $Duration, $gateSkip)

    $failDelta = 0L
    if ($rc -ne 0) {
        $Context['Failed'] = [long]$Context['Failed'] + 1
        $failDelta = 1L
        $Context['AggregateRc'] = 1
    }

    $Context['Records'].Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f
            $ScriptPath, $family, $expected, $rc, $Duration, $gateSkip))
    Add-FmTestRunFamilyTotal -Context $Context -Family $family -Duration $Duration -FailedDelta $failDelta
    $Context['Total'] = [long]$Context['Total'] + 1
}

<#
.SYNOPSIS
The run_one_serial twin.
#>
function Invoke-FmTestRunSerialScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Context,
        [Parameter(Mandatory, Position = 1)][string]$ScriptPath
    )
    $family = Get-FmTestRunFamily (Get-FmTestRunBaseName $ScriptPath)
    $expected = Get-FmTestRunExpectedGateSkip $family
    $beginIso = Get-FmTestRunIsoTime
    $beginMs = Get-FmTestRunEpochMs

    Write-FmOut ("FM_TEST_BEGIN {0} {1} family={2} expected_gate_skip={3}" -f
        $beginIso, $ScriptPath, $family, $expected)

    $run = Invoke-FmTestRunScriptProcess -ScriptPath $ScriptPath -WorkingDirectory $Context['Root'] -Stream
    $endMs = Get-FmTestRunEpochMs
    $endIso = Get-FmTestRunIsoTime
    $duration = $endMs - $beginMs
    if ($duration -lt 0) { $duration = 0 }
    Register-FmTestRunResult -Context $Context -ScriptPath $ScriptPath -ExitCode ([int]$run['ExitCode']) `
        -Duration $duration -Output ([string]$run['Output']) -EndIso $endIso
}

<#
.SYNOPSIS
The --jobs scheduler twin: bounded concurrency over the proven-isolated set.
.DESCRIPTION
Same shape as the bash scheduler: a slot table, a refill on the FIRST completed
worker rather than the oldest (the bash twin has an explicit test for that),
FM_TEST_BEGIN printed at launch, captured output replayed at completion so
markers stay ordered, and each worker given a private mode-0700 root with
TMPDIR/TMP pointed into it and the ambient FM_* overrides cleared.

PowerShell has no `jobs -r -p`, and needs none: a Process object answers
HasExited about the child this scheduler started, which is exactly the question
the bash twin's job-table walk is working around.
#>
function Invoke-FmTestRunParallel {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Context)

    $runTmp = $Context['RunTmp']
    $jobs = [int]$Context['Jobs']
    $workers = [System.Collections.Generic.List[hashtable]]::new()
    $workerN = 0

    foreach ($scriptPath in $Context['Scripts']) {
        while ($workers.Count -ge $jobs) {
            Complete-FmTestRunWorker -Context $Context -Worker $workers
        }
        $workerN++
        $work = [System.IO.Path]::Combine($runTmp, "w$workerN")
        $workerTmp = [System.IO.Path]::Combine($work, 'tmp')
        # Create then set: an mkdir -m can still be umask-adjusted on some
        # platforms, which is why the bash twin also splits the two steps.
        New-FmTestRunDirectory $work
        New-FmTestRunDirectory $workerTmp
        Set-FmTestRunPrivateDirectory $work
        Set-FmTestRunPrivateDirectory $workerTmp

        $family = Get-FmTestRunFamily (Get-FmTestRunBaseName $scriptPath)
        $expected = Get-FmTestRunExpectedGateSkip $family
        Write-FmOut ("FM_TEST_BEGIN {0} {1} family={2} expected_gate_skip={3}" -f
            (Get-FmTestRunIsoTime), $scriptPath, $family, $expected)

        # TMPDIR/TMP point only at this worker's private root so mktemp and
        # fm_test_tmproot stay private, and every ambient fleet override is
        # cleared so no two candidates can share a live home.
        $childEnv = @{
            TMPDIR               = $workerTmp
            TMP                  = $workerTmp
            FM_HOME              = $null
            FM_STATE_OVERRIDE    = $null
            FM_DATA_OVERRIDE     = $null
            FM_ROOT_OVERRIDE     = $null
            FM_PROJECTS_OVERRIDE = $null
            FM_CONFIG_OVERRIDE   = $null
            FM_BACKEND           = $null
        }
        $worker = Start-FmTestRunChild -ScriptPath $scriptPath -WorkingDirectory $Context['Root'] -Environment $childEnv
        $worker['Script'] = $scriptPath
        $worker['Work'] = $work
        $worker['BeginMs'] = Get-FmTestRunEpochMs
        $workers.Add($worker)
    }

    while ($workers.Count -gt 0) {
        Complete-FmTestRunWorker -Context $Context -Worker $workers
    }
}

<#
.SYNOPSIS
Pump the live workers until one finishes, then account for it and drop it.
.DESCRIPTION
The wait_one_completed_job_worker twin, and it refills on the FIRST completed
worker rather than the oldest launched - the property tests/fm-test-run.test.sh
checks explicitly by making the first-launched fixture the slowest. bash needs
a `jobs -r -p` inventory and a 10ms poll for that; here the pump already
returns as soon as any worker produces its last line, so the completed worker
is simply the first one marked Done.
#>
function Complete-FmTestRunWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Collections.Generic.List[hashtable]]$Worker
    )
    $index = -1
    while ($index -lt 0) {
        for ($i = 0; $i -lt $Worker.Count; $i++) {
            if ($Worker[$i]['Done']) { $index = $i; break }
        }
        if ($index -ge 0) { break }
        Step-FmTestRunChild -Worker $Worker
    }
    $w = $Worker[$index]
    $Worker.RemoveAt($index)

    $endMs = Get-FmTestRunEpochMs
    $duration = $endMs - [long]$w['BeginMs']
    if ($duration -lt 0) { $duration = 0 }
    $endIso = Get-FmTestRunIsoTime
    $output = Get-FmTestRunChildOutput $w
    $rc = [int]$w['ExitCode']
    # Replay captured output after the worker finishes so markers stay ordered.
    if ($output -ne '') { Write-FmRaw $output }
    $verdict = Test-FmTestRunWorkerRoot $w['Work']
    if (-not $verdict['Ok']) {
        Write-FmTestRunLog ("isolation failure: worker root mode is {0}, expected 0700 ({1})" -f
            $verdict['Mode'], $w['Work'])
        $rc = 1
    }
    Register-FmTestRunResult -Context $Context -ScriptPath $w['Script'] -ExitCode $rc `
        -Duration $duration -Output $output -EndIso $endIso
}

<#
.SYNOPSIS
The `chmod 0700` twin for a directory this runner just created.
.DESCRIPTION
Off Windows this really sets the mode. On Windows it is inert in exactly the
way MSYS chmod is inert on a noacl mount - the call is accepted and the mode
still reads 755 - which is the condition Test-FmTestRunWorkerRoot then probes
for. Reproducing that inertness rather than writing an ACL is what keeps the
two language trees agreeing about the same directory.
#>
function Set-FmTestRunPrivateDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is the chmod 0700 a bash twin issues unconditionally on a directory it just created; a confirmation surface would diverge from the twin and could stall a non-interactive CI lane.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    if (Test-FmWindows) { return }
    try {
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)
    } catch {
        throw [FmTestRunDie]::new("could not chmod 0700 worker root $Path")
    }
}

# --- main --------------------------------------------------------------------

<#
.SYNOPSIS
The whole argv loop and run flow of bin/fm-test-run.sh. Returns its exit code.
.DESCRIPTION
Returns rather than exits so the CLI half owns the process code and the
differential suite can drive every surface in one pwsh (see the header).
#>
function Invoke-FmTestRunMain {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Position = 1)][AllowEmptyString()][string]$CommandPath = ''
    )

    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
    $ctx = @{
        Root            = $root
        Scripts         = [System.Collections.Generic.List[string]]::new()
        ExcludeFamilies = [System.Collections.Generic.List[string]]::new()
        Records         = [System.Collections.Generic.List[string]]::new()
        FamilyRows      = [System.Collections.Generic.List[hashtable]]::new()
        FailOnGateSkip  = ''
        Jobs            = 1
        Total           = 0L
        Failed          = 0L
        SkippedGate     = 0L
        AggregateRc     = 0
        RunTmp          = ''
    }

    $runTmp = ''
    try {
        $argv = @($Arguments)
        $mode = ''
        $listOnly = $false
        $listFamilies = $false
        $listLanes = $false
        $checkCoverage = $false
        $aggregateOut = ''
        $family = ''
        $lane = ''
        $baseRef = 'origin/main'
        $jsonPath = ''
        $jobs = '1'

        # An if/elseif chain rather than `switch -Regex`: a PowerShell switch
        # evaluates EVERY clause that matches, so `--all` would run both the
        # '^--all$' arm and the catch-all '^-' unknown-option arm (verified).
        # The order below is the bash `case` order, which matters because the
        # `-*` arm must stay last among the option arms.
        $i = 0
        while ($i -lt $argv.Count) {
            $a = $argv[$i]
            $needsValue = ($argv.Count - $i -le 1)
            if ($a -ceq '--all') {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                $mode = 'all'; $i++
            } elseif ($a -ceq '--family') {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                if ($needsValue) { throw [FmTestRunDie]::new('--family requires a name') }
                $mode = 'family'; $family = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--family=')) {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                $mode = 'family'; $family = $a.Substring('--family='.Length); $i++
            } elseif ($a -ceq '--lane') {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                if ($needsValue) { throw [FmTestRunDie]::new('--lane requires a name (see --list-lanes)') }
                $mode = 'lane'; $lane = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--lane=')) {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                $mode = 'lane'; $lane = $a.Substring('--lane='.Length); $i++
            } elseif ($a -ceq '--proven-isolated') {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                $mode = 'proven-isolated'; $i++
            } elseif ($a -ceq '--changed') {
                if ($mode -ne '') { throw [FmTestRunDie]::new('only one selection mode is allowed') }
                $mode = 'changed'; $i++
            } elseif ($a -ceq '--base') {
                if ($needsValue) { throw [FmTestRunDie]::new('--base requires a git ref') }
                $baseRef = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--base=')) {
                $baseRef = $a.Substring('--base='.Length); $i++
            } elseif ($a -ceq '--json') {
                if ($needsValue) { throw [FmTestRunDie]::new('--json requires a path') }
                $jsonPath = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--json=')) {
                $jsonPath = $a.Substring('--json='.Length); $i++
            } elseif ($a -ceq '--jobs') {
                if ($needsValue) { throw [FmTestRunDie]::new('--jobs requires a positive integer') }
                $jobs = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--jobs=')) {
                $jobs = $a.Substring('--jobs='.Length); $i++
            } elseif ($a -ceq '--list') {
                $listOnly = $true; $i++
            } elseif ($a -ceq '--list-families') {
                $listFamilies = $true; $i++
            } elseif ($a -ceq '--list-lanes') {
                $listLanes = $true; $i++
            } elseif ($a -ceq '--check-coverage') {
                $checkCoverage = $true; $i++
            } elseif ($a -ceq '--aggregate-json') {
                if ($needsValue) { throw [FmTestRunDie]::new('--aggregate-json requires an output path') }
                $aggregateOut = $argv[$i + 1]; $i += 2
                # Remaining args after options will be collected as inputs below via MODE.
                # For aggregation we accept only input JSON paths as free args after this.
                $mode = 'aggregate'
            } elseif ($a -ceq '--exclude-family') {
                if ($needsValue) { throw [FmTestRunDie]::new('--exclude-family requires a name') }
                $ctx['ExcludeFamilies'].Add($argv[$i + 1]); $i += 2
            } elseif ($a.StartsWith('--exclude-family=')) {
                $ctx['ExcludeFamilies'].Add($a.Substring('--exclude-family='.Length)); $i++
            } elseif ($a -ceq '--fail-on-gate-skip') {
                if ($needsValue) {
                    throw [FmTestRunDie]::new("--fail-on-gate-skip requires a token (e.g. 'herdr not found')")
                }
                $ctx['FailOnGateSkip'] = $argv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--fail-on-gate-skip=')) {
                $ctx['FailOnGateSkip'] = $a.Substring('--fail-on-gate-skip='.Length); $i++
            } elseif ($a -ceq '-h' -or $a -ceq '--help') {
                Show-FmTestRunUsage $CommandPath
                return 0
            } elseif ($a -ceq '--') {
                $i++
                while ($i -lt $argv.Count) { $ctx['Scripts'].Add($argv[$i]); $i++ }
            } elseif ($a.StartsWith('-')) {
                throw [FmTestRunDie]::new("unknown option: $a")
            } else {
                if ($mode -eq 'aggregate') { $ctx['Scripts'].Add($a) }
                elseif ($mode -eq '' -or $mode -eq 'scripts') { $mode = 'scripts'; $ctx['Scripts'].Add($a) }
                else { throw [FmTestRunDie]::new("script paths cannot be combined with --$mode") }
                $i++
            }
        }

        if ($listFamilies) {
            foreach ($f in (Get-FmTestRunKnownFamily)) { Write-FmOut $f }
            return 0
        }
        if ($listLanes) {
            foreach ($l in (Get-FmTestRunKnownLane)) { Write-FmOut $l }
            return 0
        }
        if ($checkCoverage) {
            if (Test-FmTestRunCoverage $ctx) { return 0 }
            return 1
        }

        if ($mode -eq 'aggregate') {
            if ($aggregateOut -eq '') { throw [FmTestRunDie]::new('--aggregate-json requires an output path') }
            if ($ctx['Scripts'].Count -eq 0) {
                throw [FmTestRunDie]::new('--aggregate-json requires at least one input timing JSON')
            }
            foreach ($s in $ctx['Scripts']) {
                if (-not [System.IO.File]::Exists((Resolve-FmTestRunPath -Root $root -Path $s))) {
                    throw [FmTestRunDie]::new("aggregate input not found: $s")
                }
            }
            Merge-FmTestRunTimingJson -OutPath (Resolve-FmTestRunPath -Root $root -Path $aggregateOut) `
                -InputPath @($ctx['Scripts']) -Root $root
            return 0
        }

        if ($jobs -eq '' -or $jobs -notmatch '^[0-9]+$') {
            throw [FmTestRunDie]::new('--jobs must be a positive integer')
        }
        $jobsN = [int]$jobs
        if ($jobsN -lt 1) { throw [FmTestRunDie]::new('--jobs must be >= 1') }
        if ($jobsN -gt $script:FmTestRunJobsMax) {
            throw [FmTestRunDie]::new("--jobs is capped at $($script:FmTestRunJobsMax) (got $jobs)")
        }
        $ctx['Jobs'] = $jobsN

        $selectionDesc = ''
        switch ($mode) {
            'all' { Select-FmTestRunAll $ctx; $selectionDesc = 'all' }
            'family' { Select-FmTestRunFamily -Context $ctx -Family $family; $selectionDesc = "family=$family" }
            'lane' { Select-FmTestRunLane -Context $ctx -Lane $lane; $selectionDesc = "lane=$lane" }
            'proven-isolated' { Select-FmTestRunProvenIsolated $ctx; $selectionDesc = 'proven-isolated' }
            'changed' { Select-FmTestRunChanged -Context $ctx -BaseRef $baseRef; $selectionDesc = "changed:base=$baseRef" }
            'scripts' {
                # Normalize and re-add through Add-FmTestRunScript for consistent paths.
                $raw = @($ctx['Scripts'])
                $ctx['Scripts'] = [System.Collections.Generic.List[string]]::new()
                foreach ($s in $raw) { Add-FmTestRunScript -Context $ctx -Path $s }
                $selectionDesc = 'scripts'
            }
            default {
                throw [FmTestRunDie]::new('select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)')
            }
        }

        Remove-FmTestRunExcludedFamily $ctx
        if ($ctx['ExcludeFamilies'].Count -gt 0) {
            $selectionDesc = "$selectionDesc;exclude-family=" + (($ctx['ExcludeFamilies']) -join ',')
        }
        if ($ctx['FailOnGateSkip'] -ne '') {
            $selectionDesc = "$selectionDesc;fail-on-gate-skip=" + $ctx['FailOnGateSkip']
        }
        if ($jobsN -gt 1) { $selectionDesc = "$selectionDesc;jobs=$jobsN" }

        if ($listOnly) {
            foreach ($s in $ctx['Scripts']) { Write-FmOut $s }
            return 0
        }

        if ($ctx['Scripts'].Count -eq 0) {
            Write-FmTestRunLog 'nothing to run'
            Write-FmOut 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0'
            if ($jsonPath -ne '') {
                $started = Get-FmTestRunIsoTime
                $out = Resolve-FmTestRunPath -Root $root -Path $jsonPath
                New-FmTestRunDirectory ([System.IO.Path]::GetDirectoryName($out))
                Write-FmTestRunTimingJson -Path $out -Started $started -Finished $started -RunId 'empty' `
                    -Total 0 -Failed 0 -Skipped 0 -Duration 0 -Selection $selectionDesc -Records @() -Families @()
            }
            return 0
        }

        # Verify selected scripts exist before starting.
        foreach ($s in $ctx['Scripts']) {
            $native = Resolve-FmTestRunPath -Root $root -Path $s
            if (-not [System.IO.File]::Exists($native)) { throw [FmTestRunDie]::new("test script not found: $s") }
            try { [System.IO.File]::OpenRead($native).Dispose() }
            catch { throw [FmTestRunDie]::new("test script not readable: $s") }
        }

        # --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
        if ($jobsN -gt 1) {
            foreach ($s in $ctx['Scripts']) {
                if (-not (Test-FmTestRunProvenIsolated $s)) {
                    throw [FmTestRunDie]::new("--jobs $jobsN refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial.")
                }
            }
        }

        $tmpBase = ConvertTo-FmNativePath (Get-FmEnv 'TMPDIR' ([System.IO.Path]::GetTempPath()))
        $runTmp = [System.IO.Path]::Combine($tmpBase, 'fm-test-run.' + [System.IO.Path]::GetRandomFileName())
        New-FmTestRunDirectory $runTmp
        $ctx['RunTmp'] = $runTmp

        $runStartedIso = Get-FmTestRunIsoTime
        $runStartedMs = Get-FmTestRunEpochMs
        $runId = "fm-test-run-$runStartedMs-$PID"

        if ($jobsN -eq 1) {
            foreach ($s in $ctx['Scripts']) { Invoke-FmTestRunSerialScript -Context $ctx -ScriptPath $s }
        } else {
            Invoke-FmTestRunParallel $ctx
        }

        $runFinishedIso = Get-FmTestRunIsoTime
        $runFinishedMs = Get-FmTestRunEpochMs
        $runDuration = $runFinishedMs - $runStartedMs
        if ($runDuration -lt 0) { $runDuration = 0 }

        Write-FmOut ("FM_TEST_SUMMARY total={0} failed={1} skipped_gate={2} duration_ms={3}" -f
            $ctx['Total'], $ctx['Failed'], $ctx['SkippedGate'], $runDuration)

        # Stable family summary order by name.
        $familyLines = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $ctx['FamilyRows']) {
            $familyLines.Add(("{0}`t{1}`t{2}`t{3}" -f $row['Name'], $row['Count'], $row['Duration'], $row['Failed']))
        }
        $familyLines = [System.Collections.Generic.List[string]](Get-FmTestRunSorted $familyLines)
        foreach ($line in $familyLines) {
            $f = @($line.Split("`t"))
            Write-FmOut ("FM_TEST_SUMMARY_FAMILY family={0} count={1} duration_ms={2} failed={3}" -f
                $f[0], $f[1], $f[2], $f[3])
        }

        # Slowest scripts (top 15) from records.
        if ($ctx['Records'].Count -gt 0) {
            # `sort -t$'\t' -k5,5nr`: numeric on the duration field, and GNU
            # sort's last-resort whole-line comparison is reversed too, so equal
            # durations order by the record line DESCENDING.
            $ranked = @($ctx['Records'] | Sort-Object -Property `
                @{ Expression = { [long](@($_.Split("`t")))[4] }; Descending = $true }, `
                @{ Expression = { $_ }; Descending = $true })
            $rank = 1
            foreach ($record in $ranked) {
                if ($rank -gt 15) { break }
                $f = @($record.Split("`t"))
                Write-FmOut ("FM_TEST_SLOWEST rank={0} script={1} duration_ms={2}" -f $rank, $f[0], $f[4])
                $rank++
            }
        }

        if ($jsonPath -ne '') {
            $out = Resolve-FmTestRunPath -Root $root -Path $jsonPath
            New-FmTestRunDirectory ([System.IO.Path]::GetDirectoryName($out))
            Write-FmTestRunTimingJson -Path $out -Started $runStartedIso -Finished $runFinishedIso -RunId $runId `
                -Total $ctx['Total'] -Failed $ctx['Failed'] -Skipped $ctx['SkippedGate'] -Duration $runDuration `
                -Selection $selectionDesc -Records @($ctx['Records']) -Families @($familyLines)
            Write-FmTestRunLog "wrote timing artifact: $jsonPath"
        }

        return [int]$ctx['AggregateRc']
    } catch [FmTestRunDie] {
        Write-FmTestRunLog $_.Exception.Message
        return 2
    } finally {
        # The `trap 'rm -rf "$RUN_TMP"' EXIT` twin.
        if ($runTmp -ne '' -and [System.IO.Directory]::Exists($runTmp)) {
            try { [System.IO.Directory]::Delete($runTmp, $true) } catch { $null = $_ }
        }
    }
}

Export-ModuleMember -Function @(
    'Write-FmTestRunLog', 'Show-FmTestRunUsage',
    'Get-FmTestRunIsoTime', 'Get-FmTestRunEpochMs',
    'Get-FmTestRunBaseName', 'Resolve-FmTestRunPath', 'Test-FmTestRunGlob', 'Test-FmTestRunGlobAny',
    'ConvertTo-FmTestRunScriptPath',
    'Get-FmTestRunSortedUnique', 'Get-FmTestRunSorted', 'Get-FmTestRunSetDiff',
    'Get-FmTestRunSetIntersect', 'Get-FmTestRunSetDuplicate', 'Get-FmTestRunSetSymmetric',
    'Get-FmTestRunFamily', 'Get-FmTestRunExpectedGateSkip', 'Get-FmTestRunKnownFamily',
    'Get-FmTestRunKnownLane', 'Get-FmTestRunProvenIsolated', 'Get-FmTestRunPortableShard',
    'Get-FmTestRunPortableSerialWeight', 'Get-FmTestRunPortableSerialAssignment',
    'Get-FmTestRunPortableSerialShardIndex',
    'Test-FmTestRunProvenIsolated',
    'Get-FmTestRunRepoTest', 'Add-FmTestRunScript', 'Select-FmTestRunAll',
    'Select-FmTestRunProvenIsolated', 'Select-FmTestRunFamily', 'Select-FmTestRunLane',
    'Get-FmTestRunFamilyForReference', 'Get-FmTestRunFamilyForChangedPath', 'Select-FmTestRunChanged',
    'Remove-FmTestRunExcludedFamily', 'Test-FmTestRunCoverage',
    'ConvertTo-FmTestRunJson', 'ConvertTo-FmTestRunJsonString', 'ConvertTo-FmTestRunInt',
    'ConvertFrom-FmTestRunJson', 'Convert-FmTestRunJsonElement',
    'New-FmTestRunDirectory', 'Write-FmTestRunTimingJson', 'Merge-FmTestRunTimingJson',
    'Test-FmTestRunGateSkip', 'Test-FmTestRunGateSkipToken',
    'Get-FmTestRunDirMode', 'Test-FmTestRunModeEnforcementInert', 'Get-FmTestRunPathOwner',
    'Get-FmTestRunCurrentOwner', 'Test-FmTestRunWorkerRoot', 'Set-FmTestRunPrivateDirectory',
    'Start-FmTestRunChild', 'Step-FmTestRunChild', 'Get-FmTestRunChildOutput',
    'Invoke-FmTestRunScriptProcess', 'Add-FmTestRunFamilyTotal', 'Register-FmTestRunResult',
    'Invoke-FmTestRunSerialScript', 'Invoke-FmTestRunParallel', 'Complete-FmTestRunWorker',
    'Invoke-FmTestRunMain'
)
