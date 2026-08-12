#Requires -Version 7.0
# fm-test-isolation-proof.sh - bounded concurrent isolation proof for portable
# behavior-test candidates (Phase 2 pre-shard gate).
#
# This is the single owner of the proven parallel candidate set, the concurrent
# proof run, and the isolation checks that admitted that set. Production
# portable CI shards and bounded local fm-test-run.sh --jobs for this exact set
# are owned by bin/fm-test-run.sh (docs/fm-test-portable-shards.md).
#
# It does NOT:
#   - compose production CI shard membership (fm-test-run.sh owns that partition)
#   - run real Herdr, real default-server tmux, watcher lock races, AFK, live
#     harnesses, or GUI backends
#
# Usage:
#   fm-test-isolation-proof.sh [--jobs N] [--json path] [--list]
#   fm-test-isolation-proof.sh --list-exclusions
#   fm-test-isolation-proof.sh -h | --help
#
# Options:
#   --jobs N     max concurrent workers (default: 4; min 1)
#   --json path  write a machine-readable proof artifact after the run
#   --list       print the proven candidate paths (one per line) and exit 0
#   --list-exclusions
#                print basename + reason for scripts deliberately kept serial
#                relative to the scout-proposed parallel pool, then exit 0
#   -h, --help   print this header
#
# Isolation contract for each concurrent worker:
#   - distinct mode-0700 temporary root under a proof-owned parent
#   - TMPDIR/TMP point only at that root so mktemp/fm_test_tmproot stay private
#   - ambient FM_HOME / FM_*_OVERRIDE cleared so no shared home is reused
#   - no global git config mutation (snapshot before/after)
#   - no production sharding and no retry-until-green
#
# Markers (stdout):
#   FM_ISOLATION_BEGIN <iso8601> concurrency=<n> candidates=<n>
#   FM_ISOLATION_CANDIDATE_BEGIN <iso8601> <script> worker=<i>
#   FM_ISOLATION_CANDIDATE_END <iso8601> <script> exit=<code> duration_ms=<n> worker=<i>
#   FM_ISOLATION_SUMMARY total=<n> failed=<n> concurrency=<n> duration_ms=<n>
#
# Exit status is the aggregate of candidate exits: non-zero if any candidate
# fails, if isolation checks fail, or if the candidate set is empty. A script
# that fails only under concurrency must be removed from the candidate set and
# investigated; this harness never retries a failure into green.

# Twin: bin/fm-test-isolation-proof.sh
#
# ---------------------------------------------------------------------------
# THE HEADER ABOVE IS THE BASH FILE'S, VERBATIM
#
# The bash twin prints its own header as --help with
# `awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"`,
# and docs/powershell-port.md contract 4 requires that surface to stay
# identical during the transition. `#Requires` sits at line 1 because it is the
# only thing that can, and it is skipped by the same rule awk applies to the
# shebang; the blank line above ends the block where `set -eu` ends it in bash.
#
# ---------------------------------------------------------------------------
# WHY THIS ONE IMPORTS fm-test-run.psm1 WHEN ITS TWIN DUPLICATES THE CODE
#
# bin/fm-test-isolation-proof.sh re-implements now_iso, now_ms, dir_mode and
# write_json_artifact instead of reusing bin/fm-test-run.sh's copies. That is
# not a style choice: bash's only reuse mechanism is `source`, and sourcing
# fm-test-run.sh would EXECUTE its argv parsing and its whole main body, so the
# duplication is forced by the language. PowerShell has a real module, the two
# files are one package with one owner, and the shared pieces here are exactly
# the ones whose byte-for-byte behavior must not drift between them - the
# python-compatible JSON writer and the inert-chmod isolation gate most of all.
# So this imports rather than copies, and any divergence becomes impossible
# instead of merely unlikely.
#
# ---------------------------------------------------------------------------
# THE mode-0700 WORKER GATE ON AN INERT-chmod FILESYSTEM
#
# The bash twin DIES outright when a freshly created worker root does not read
# 0700, which on Windows it never can: Git Bash mounts drives and /tmp
# `noacl,posix=0,usertemp`, so chmod is accepted and provably changes nothing
# (measured: `mkdir -p d; chmod 0700 d; stat -c %a d` prints 755). This twin
# uses the same answer the bash tree already gives this exact situation
# (fm_pr_mode_enforcement_inert in bin/fm-pr-lib.sh): probe whether chmod is
# inert on that parent, and only when it provably is, accept the root on
# OWNERSHIP instead of the mode bit. On a mode-honoring host nothing changes.
# Enforcing real NTFS ACLs here instead was rejected deliberately - it would
# make the PowerShell path refuse roots the bash path accepts, and both trees
# are live against this machine during the transition. See
# bin/fm-test-run.psm1's header and inventory R6.
#
# ---------------------------------------------------------------------------
# NO param() BLOCK, and $args CAPTURED FIRST - same two reasons as
# bin/fm-test-run.ps1: `-h` must not be bound as a parameter, and `$args`
# inside a script block is that block's own empty array.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-test-run.psm1') -Force

$fmArgv = @($args)
$fmCommandPath = $PSCommandPath

$script:FmProofPrefix = 'fm-test-isolation-proof'

# The die() twin. A plain sentinel-tagged exception rather than a class: this
# file has no module to declare one in, and the tag is checked at exactly one
# place, so it cannot be confused with a real fault.
$script:FmProofDieTag = 'fm-test-isolation-proof-die: '

function Write-FmProofLog {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message)
    Write-FmErr "${script:FmProofPrefix}: $Message"
}

function Show-FmProofUsage {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$CommandPath)
    $lines = (Get-FmFileLines $CommandPath)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].StartsWith('#')) { break }
        Write-FmErr ($lines[$i] -replace '^# ?', '')
    }
}

# Serial exclusions relative to the scout-proposed parallel pool (pure units,
# fake backends, private git fixtures, stubbed network). Reasons are audit
# evidence; do not re-add a basename without clearing its reason.
$script:FmProofExclusionReason = @{}
foreach ($group in @(
        @{ Reason = 'isolation-proof harness contract itself; must not re-enter concurrent matrix'
            Names  = @('fm-test-isolation-proof.test.sh') }
        @{ Reason = 'real tmux on a private socket; keep exclusive of default-server contention class'
            Names  = @('fm-backend-tmux-smoke.test.sh') }
        @{ Reason = 'old-vs-new main checkout diff fixture; gray-zone concurrent git/worktree cost'
            Names  = @('fm-backend.test.sh') }
        @{ Reason = 'real isolated git worktrees plus spawn settle loops; gray zone until dedicated proof'
            Names  = @('fm-spawn-dispatch-profile.test.sh', 'fm-spawn-worktree-settle.test.sh',
                'fm-trace-context-spawn.test.sh') }
        @{ Reason = 'watcher lock / migration / poll security surface; intentional shared-lock class'
            Names  = @('fm-pr-check-security.test.sh') }
        @{ Reason = 'landed-work + lock-race teardown matrix; keep serial with forge/git stress peers'
            Names  = @('fm-teardown.test.sh') }
        @{ Reason = 'session-start task/presentation lock matrix; keep serial until dedicated concurrent proof'
            Names  = @('fm-herdr-session-cleanup.test.sh') }
        @{ Reason = 'watcher/wake/lock family; intentional process locks and daemon races'
            Names  = @('fm-daemon.test.sh', 'fm-guard-stale-banner.test.sh', 'fm-pi-watch-extension.test.sh',
                'fm-supervision-events.test.sh', 'fm-turnend-guard.test.sh',
                'fm-wake-daemon-lifecycle-e2e.test.sh', 'fm-wake-queue.test.sh',
                'fm-watch-checkpoint.test.sh', 'fm-watch-triage.test.sh', 'fm-watcher-lock.test.sh') }
        @{ Reason = 'AFK lifecycle / inject path; exclusive daemon and pane control'
            Names  = @('fm-afk-inject-e2e.test.sh', 'fm-afk-return.test.sh',
                'fm-afk-inject-herdr-e2e.test.sh', 'fm-afk-launch.test.sh') }
        @{ Reason = 'live harness opt-in; never default parallel CI'
            Names  = @('fm-afk-pi-herdr-return-e2e.test.sh', 'fm-codex-continuity-live-e2e.test.sh',
                'fm-grok-continuity-live-e2e.test.sh', 'fm-opencode-primary-live-e2e.test.sh',
                'fm-pi-primary-live-e2e.test.sh', 'fm-quota-array-dispatch-live-e2e.test.sh',
                'fm-send-secondmate-marker-herdr-e2e.test.sh') }
        @{ Reason = 'real Herdr-gated; Herdr lane is a later phase'
            Names  = @('fm-backend-autodetect-smoke.test.sh', 'fm-backend-herdr-eventwait-smoke.test.sh',
                'fm-backend-herdr-presentation-e2e.test.sh', 'fm-backend-herdr-prune-safety-e2e.test.sh',
                'fm-backend-herdr-respawn-idem-e2e.test.sh', 'fm-backend-herdr-smoke.test.sh',
                'fm-backend-herdr-workspace-per-home-e2e.test.sh', 'fm-herdr-session-cleanup-e2e.test.sh') }
        @{ Reason = 'cmux GUI backend; never parallel with another cmux mutator'
            Names  = @('fm-backend-cmux.test.sh', 'fm-backend-cmux-smoke.test.sh') }
        @{ Reason = 'zellij optional backend; keep out of pure parallel pool'
            Names  = @('fm-backend-zellij.test.sh', 'fm-backend-zellij-smoke.test.sh') }
        @{ Reason = 'orca backend surface; keep serial until dedicated isolation proof'
            Names  = @('fm-backend-orca.test.sh') }
    )) {
    foreach ($name in $group['Names']) { $script:FmProofExclusionReason[$name] = $group['Reason'] }
}

# Exact candidate set from the archived concurrent proof. Adding or removing a
# path requires a new audit and proof archive.
$script:FmProofCandidates = @(
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

# The order the bash here-doc feeds to exclusion_reason; the report is that
# order, not the map's, so it stays a stable audit artifact.
$script:FmProofExclusionReport = @(
    'fm-test-isolation-proof.test.sh'
    'fm-backend-tmux-smoke.test.sh'
    'fm-backend.test.sh'
    'fm-spawn-dispatch-profile.test.sh'
    'fm-spawn-worktree-settle.test.sh'
    'fm-trace-context-spawn.test.sh'
    'fm-pr-check-security.test.sh'
    'fm-teardown.test.sh'
    'fm-watcher-lock.test.sh'
    'fm-wake-queue.test.sh'
    'fm-afk-inject-e2e.test.sh'
    'fm-backend-herdr-smoke.test.sh'
    'fm-backend-cmux-smoke.test.sh'
    'fm-pi-primary-live-e2e.test.sh'
    'fm-quota-array-dispatch-live-e2e.test.sh'
)

<#
.SYNOPSIS
The global_git_snapshot twin: `git config --global --list | LC_ALL=C sort`.
.DESCRIPTION
Empty string when no global config is present or git cannot read it, matching
the bash twin's `2>/dev/null ... || true`.
#>
function Get-FmProofGitSnapshot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $result = Invoke-FmTool 'git' @('config', '--global', '--list')
        $lines = @(($result['StdOut'] -split "`n") | Where-Object { $_ -ne '' })
        return ((Get-FmTestRunSorted $lines) -join "`n")
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
The `tail -n 40` twin over a captured stream.
#>
function Get-FmProofTail {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Position = 1)][int]$Count = 40
    )
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @(($Text -replace "`r", '') -split "`n")
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
    if ($lines.Count -le $Count) { return @($lines) }
    return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
}

<#
.SYNOPSIS
Start one candidate with its own private TMPDIR and no ambient fleet overrides.
.DESCRIPTION
stdout and stderr stay SEPARATE here (the bash twin redirects them to two
files), so each is drained with a single ReadToEndAsync rather than the
line-merging pump bin/fm-test-run.psm1 needs - both tasks run in the background
while this returns, which is what makes the workers genuinely concurrent.
#>
function Start-FmProofCandidate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This starts the candidate process its bash twin starts unconditionally inside the proof run; a confirmation surface would diverge from the twin and could stall a non-interactive proof.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ScriptPath,
        [Parameter(Mandatory, Position = 1)][string]$Root,
        [Parameter(Mandatory, Position = 2)][string]$WorkerTmp
    )
    $bash = Get-FmBash
    if (-not $bash) {
        return @{ Proc = $null; Out = $null; Err = $null; NoBash = $true }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $bash
    $psi.ArgumentList.Add((ConvertTo-FmPosixPath (Resolve-FmTestRunPath -Root $Root -Path $ScriptPath)))
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = ConvertTo-FmNativePath $Root
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.Environment['TMPDIR'] = $WorkerTmp
    $psi.Environment['TMP'] = $WorkerTmp
    # Clear ambient fleet overrides so candidates cannot share a live home.
    foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_ROOT_OVERRIDE',
            'FM_PROJECTS_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_BACKEND')) {
        [void]$psi.Environment.Remove($name)
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    return @{
        Proc   = $proc
        Out    = $proc.StandardOutput.ReadToEndAsync()
        Err    = $proc.StandardError.ReadToEndAsync()
        NoBash = $false
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
    $proofRoot = ''
    try {
        $jobs = '4'
        $jsonPath = ''
        $listOnly = $false
        $listExclusions = $false

        # An if/elseif chain rather than `switch -Regex`: a PowerShell switch
        # runs EVERY matching clause, so '--jobs' would also hit the unknown
        # option arm.
        $i = 0
        while ($i -lt $fmArgv.Count) {
            $a = $fmArgv[$i]
            $needsValue = ($fmArgv.Count - $i -le 1)
            if ($a -ceq '--jobs') {
                if ($needsValue) { throw ($script:FmProofDieTag + '--jobs requires a positive integer') }
                $jobs = $fmArgv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--jobs=')) {
                $jobs = $a.Substring('--jobs='.Length); $i++
            } elseif ($a -ceq '--json') {
                if ($needsValue) { throw ($script:FmProofDieTag + '--json requires a path') }
                $jsonPath = $fmArgv[$i + 1]; $i += 2
            } elseif ($a.StartsWith('--json=')) {
                $jsonPath = $a.Substring('--json='.Length); $i++
            } elseif ($a -ceq '--list') {
                $listOnly = $true; $i++
            } elseif ($a -ceq '--list-exclusions') {
                $listExclusions = $true; $i++
            } elseif ($a -ceq '-h' -or $a -ceq '--help') {
                Show-FmProofUsage $fmCommandPath
                Exit-FmScript 0
            } elseif ($a.StartsWith('-')) {
                throw ($script:FmProofDieTag + "unknown option: $a")
            } else {
                throw ($script:FmProofDieTag + "unexpected argument: $a (this harness owns its candidate set)")
            }
        }

        if ($jobs -eq '' -or $jobs -notmatch '^[0-9]+$') {
            throw ($script:FmProofDieTag + '--jobs must be a positive integer')
        }
        $jobsN = [int]$jobs
        if ($jobsN -lt 1) { throw ($script:FmProofDieTag + '--jobs must be >= 1') }

        if ($listExclusions) {
            foreach ($base in $script:FmProofExclusionReport) {
                if ($base -eq '') { continue }
                if ($script:FmProofExclusionReason.ContainsKey($base)) {
                    Write-FmOut ("{0}`t{1}" -f $base, $script:FmProofExclusionReason[$base])
                }
            }
            Exit-FmScript 0
        }

        $candidates = @(Get-FmTestRunSortedUnique $script:FmProofCandidates)

        if ($listOnly) {
            foreach ($s in $candidates) { Write-FmOut $s }
            Exit-FmScript 0
        }

        if ($candidates.Count -eq 0) {
            throw ($script:FmProofDieTag + 'candidate set is empty; refusing isolation proof')
        }
        foreach ($s in $candidates) {
            if (-not [System.IO.File]::Exists((Resolve-FmTestRunPath -Root $root -Path $s))) {
                throw ($script:FmProofDieTag + "candidate not found: $s")
            }
        }

        $tmpBase = ConvertTo-FmNativePath (Get-FmEnv 'TMPDIR' ([System.IO.Path]::GetTempPath()))
        $proofRoot = [System.IO.Path]::Combine($tmpBase, 'fm-isolation-proof.' + [System.IO.Path]::GetRandomFileName())
        New-FmTestRunDirectory $proofRoot
        Set-FmTestRunPrivateDirectory $proofRoot
        $proofVerdict = Test-FmTestRunWorkerRoot $proofRoot
        if (-not $proofVerdict['Ok']) {
            throw ($script:FmProofDieTag + "could not chmod 0700 proof root $proofRoot")
        }
        $records = [System.Collections.Generic.List[string]]::new()

        $gitBefore = Get-FmProofGitSnapshot
        $runStartedIso = Get-FmTestRunIsoTime
        $runStartedMs = Get-FmTestRunEpochMs
        $runId = "fm-isolation-$runStartedMs-$PID"
        $total = $candidates.Count
        # A HASHTABLE, not two plain variables, because the reaper below is a
        # script block invoked with `&` and therefore runs in a CHILD SCOPE:
        # `$failed++` inside it would create a new local and the outer count
        # would stay 0, so every candidate failure would be silently swallowed
        # and the harness would exit 0 on a red run. Mutating a hashtable's
        # entries crosses the scope boundary because the object is shared.
        $tally = @{ Failed = 0; AggRc = 0 }

        Write-FmOut ("FM_ISOLATION_BEGIN {0} concurrency={1} candidates={2}" -f
            $runStartedIso, $jobsN, $total)

        # Worker state, parallel to CANDIDATES indices (1-based worker labels).
        $workers = [System.Collections.Generic.List[hashtable]]::new()

        # wait_one_slot: reaps the OLDEST launched worker, not the first to
        # finish. That ordering is the contract - every CANDIDATE_END marker and
        # every record row comes out in launch order - so this stays FIFO even
        # though a completion-ordered reap would be cheaper.
        $waitOneSlot = {
            $w = $workers[0]
            $workers.RemoveAt(0)
            $rc = 1
            $duration = 0L
            $stdout = ''
            $stderr = ''
            if ($w['NoBash']) {
                $stderr = "fm-test-isolation-proof: no bash available to run $($w['Script'])`n"
            } else {
                $stdout = ($w['Out'].GetAwaiter().GetResult() -replace "`r", '')
                $stderr = ($w['Err'].GetAwaiter().GetResult() -replace "`r", '')
                $w['Proc'].WaitForExit()
                $rc = $w['Proc'].ExitCode
                $w['Proc'].Dispose()
                $duration = (Get-FmTestRunEpochMs) - [long]$w['BeginMs']
                if ($duration -lt 0) { $duration = 0 }
            }
            $script = $w['Script']
            $idx = $w['Index']
            Write-FmOut ("FM_ISOLATION_CANDIDATE_END {0} {1} exit={2} duration_ms={3} worker={4}" -f
                (Get-FmTestRunIsoTime), $script, $rc, $duration, $idx)
            $records.Add(("{0}`t{1}`t{2}`t{3}" -f $script, $rc, $duration, $idx))
            if ($rc -ne 0) {
                $tally['Failed']++
                $tally['AggRc'] = 1
                Write-FmProofLog "candidate failed: $script exit=$rc"
                $outTail = @(Get-FmProofTail $stdout 40)
                if ($outTail.Count -gt 0) {
                    Write-FmProofLog "--- stdout ($script) ---"
                    foreach ($line in $outTail) { Write-FmErr $line }
                }
                $errTail = @(Get-FmProofTail $stderr 40)
                if ($errTail.Count -gt 0) {
                    Write-FmProofLog "--- stderr ($script) ---"
                    foreach ($line in $errTail) { Write-FmErr $line }
                }
            }
            # Isolation: worker root must remain mode 0700 and under the proof parent.
            $verdict = Test-FmTestRunWorkerRoot $w['Work']
            if (-not $verdict['Ok']) {
                Write-FmProofLog ("isolation failure: worker root mode is {0}, expected 0700 ({1})" -f
                    $verdict['Mode'], $w['Work'])
                $tally['AggRc'] = 1
                $tally['Failed']++
            }
            if (-not $w['Work'].StartsWith($proofRoot + [System.IO.Path]::DirectorySeparatorChar)) {
                Write-FmProofLog "isolation failure: worker root escaped proof parent: $($w['Work'])"
                $tally['AggRc'] = 1
            }
        }

        $idx = 0
        foreach ($script in $candidates) {
            $idx++
            $work = [System.IO.Path]::Combine($proofRoot, "w$idx")
            $workTmp = [System.IO.Path]::Combine($work, 'tmp')
            $workOut = [System.IO.Path]::Combine($work, 'out')
            # Create then chmod: mkdir -m can still be umask-adjusted on some platforms.
            New-FmTestRunDirectory $work
            New-FmTestRunDirectory $workTmp
            New-FmTestRunDirectory $workOut
            Set-FmTestRunPrivateDirectory $work
            Set-FmTestRunPrivateDirectory $workTmp
            Set-FmTestRunPrivateDirectory $workOut
            $verdict = Test-FmTestRunWorkerRoot $work
            if (-not $verdict['Ok']) {
                throw ($script:FmProofDieTag +
                    "failed to create mode-0700 worker root at $work (mode=$($verdict['Mode']))")
            }
            $verdict = Test-FmTestRunWorkerRoot $workTmp
            if (-not $verdict['Ok']) {
                throw ($script:FmProofDieTag +
                    "failed to create mode-0700 TMPDIR at $workTmp (mode=$($verdict['Mode']))")
            }

            Write-FmOut ("FM_ISOLATION_CANDIDATE_BEGIN {0} {1} worker={2}" -f
                (Get-FmTestRunIsoTime), $script, $idx)

            $w = Start-FmProofCandidate -ScriptPath $script -Root $root -WorkerTmp $workTmp
            $w['Script'] = $script
            $w['Index'] = $idx
            $w['Work'] = $work
            $w['BeginMs'] = Get-FmTestRunEpochMs
            $workers.Add($w)

            # Bound concurrency.
            while ($workers.Count -ge $jobsN) { & $waitOneSlot }
        }

        while ($workers.Count -gt 0) { & $waitOneSlot }

        $gitAfter = Get-FmProofGitSnapshot
        if ($gitBefore -ne $gitAfter) {
            Write-FmProofLog 'isolation failure: git config --global changed during the concurrent proof'
            Write-FmProofLog '--- before ---'
            Write-FmErr $gitBefore
            Write-FmProofLog '--- after ---'
            Write-FmErr $gitAfter
            $tally['AggRc'] = 1
            $tally['Failed']++
        }

        # The bash twin's cross-process artifact check is a literal no-op: its
        # `find ... | grep -q .` guard has `:` as its only body and no else
        # branch, because every worker's TMPDIR already lives under the proof
        # root the trap removes. Reproducing a filesystem walk that can produce
        # no output and no verdict would only cost time, so it is recorded here
        # rather than re-run.

        $runFinishedIso = Get-FmTestRunIsoTime
        $runDuration = (Get-FmTestRunEpochMs) - $runStartedMs
        if ($runDuration -lt 0) { $runDuration = 0 }

        Write-FmOut ("FM_ISOLATION_SUMMARY total={0} failed={1} concurrency={2} duration_ms={3}" -f
            $total, $tally['Failed'], $jobsN, $runDuration)

        if ($jsonPath -ne '') {
            $out = Resolve-FmTestRunPath -Root $root -Path $jsonPath
            New-FmTestRunDirectory ([System.IO.Path]::GetDirectoryName($out))
            # Stable record order for the artifact.
            $scripts = [System.Collections.Generic.List[object]]::new()
            foreach ($line in (Get-FmTestRunSorted $records)) {
                $f = @($line.Split("`t"))
                $scripts.Add([ordered]@{
                        path        = $f[0]
                        exit        = [long]$f[1]
                        duration_ms = [long]$f[2]
                        worker      = [long]$f[3]
                    })
            }
            $doc = [ordered]@{
                run_id                     = $runId
                started_at                 = $runStartedIso
                finished_at                = $runFinishedIso
                kind                       = 'isolation-proof'
                concurrency                = [long]$jobsN
                summary                    = [ordered]@{
                    total       = [long]$total
                    failed      = [long]$tally['Failed']
                    duration_ms = [long]$runDuration
                }
                scripts                    = $scripts
                production_sharding_enabled = $false
                fm_test_run_jobs_enabled   = $false
            }
            Set-FmFileText -Path $out -Text ((ConvertTo-FmTestRunJson $doc 0) + "`n") -NoNewline
            Write-FmProofLog "wrote isolation proof artifact: $jsonPath"
        }

        Exit-FmScript $tally['AggRc']
    } catch [System.Management.Automation.ExitException] {
        throw
    } catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith($script:FmProofDieTag)) {
            Write-FmProofLog $message.Substring($script:FmProofDieTag.Length)
            Exit-FmScript 2
        }
        throw
    } finally {
        # The `trap 'rm -rf "$PROOF_ROOT"' EXIT` twin.
        if ($proofRoot -ne '' -and [System.IO.Directory]::Exists($proofRoot)) {
            try { [System.IO.Directory]::Delete($proofRoot, $true) } catch { $null = $_ }
        }
    }
}
