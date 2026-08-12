# fm-session-start.ps1 - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock, fm-bootstrap,
# fm-wake-drain, and fm-startup-network as real subprocesses and prints their
# real output. It never re-implements their logic; all sequencing/formatting
# logic added here stays local to this file. Those scripts remain fully working
# standalone with unchanged default behavior.
#
# ORDERING, and why LOCK runs before BOOTSTRAP:
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                      mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                      when this session actually holds the lock. Detect-only
#                      diagnostics always run. Bootstrap's six MUTATING sweeps
#                      also run only when locked; the network sweeps run in the
#                      deferred stage (FM_BOOTSTRAP_NETWORK=skip here), started
#                      right after the lock and harvested at step 7.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                      when locked.
#   4. supervision-instructions - the one emitted operating block for the
#                      detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                      represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                      every state/*.meta, a bounded state/*.status tail,
#                      state/.afk, and a cheap per-task endpoint-liveness read.
#   7. network checks - the result of the deferred network stage started back
#                      at step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                      data/captain-shared.md, data/learnings.md.
#   9. closing reminder - points back to the emitted harness supervision block
#                      and deliberately never arms the watcher itself.
#
# Those nine names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization. No step here makes an external-network call:
# the five that did are started as one detached bounded worker right after the
# lock (step 1) and harvested at step 7 without ever blocking on it.
# bin/fm-startup-network.sh owns that stage; bin/fm-bootstrap.sh remains the
# owner of the sweeps themselves. On a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed; it never
# reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE runs before CONTEXT: this digest is delivered
# through a harness that truncates an oversized payload from the TAIL, so what
# a truncated tail drops must be the CHEAPEST thing to lose. Curated memory is
# stable session to session and recoverable with one targeted read; live fleet
# identity changes every session and is exactly what recovery depends on. So
# fleet state goes first and the memory files absorb the truncation. The
# read-once contract moves ahead of both for the same reason.
#
# RUNTIME BOUND: the whole digest runs as ONE bounded child of this script
# (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound, in its own process group under its own
# aggregate deadline. The child writes the digest straight to this script's
# stdout, so everything it emitted before the bound was hit is already
# delivered; the parent then prints a loud STARTUP TRUNCATED banner naming the
# stage that did not finish and the sections that were therefore never
# emitted, and still exits 0. The child records its progress in
# FM_SESSION_START_STAGE_FILE, which is also the flag that tells a child it is
# the child - the parent never recurses.
#
# Usage: fm-session-start.ps1 [--reemit]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled and re-emit the
#             rest. The wake-queue drain is NOT skipped: queued records are
#             this turn's work queue. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed.

# ---------------------------------------------------------------------------
# Twin: bin/fm-session-start.sh
#
# EVERYTHING ABOVE THE BLANK LINE IS THE --help TEXT (the fm-brief.ps1
# convention): the bash twin renders --help by sed-ing its own header, and this
# file reproduces that reader over its own header, so a header edit lands in
# --help in BOTH languages. The bash header carries far more ordering rationale
# than fits here; bin/fm-session-start.sh remains the single owner of that
# prose, and this header is its adaptation, not its byte copy.
#
# FOUR MECHANICS THIS TWIN HAD TO GET RIGHT
#
#   THE RUNTIME BOUND RE-EXECUTES THIS FILE. The bash twin re-runs ITSELF under
#   fm_run_timed with FM_SESSION_START_STAGE_FILE set; the parent's only jobs
#   are the bound, the truncation banner, and exit 0. This twin mirrors that
#   shape with a real child pwsh process ([Environment]::ProcessPath -NoProfile
#   -File <this file>) whose stdout/stderr are INHERITED, not redirected: the
#   digest must stream, so everything emitted before the bound was hit is
#   already delivered when the child is killed. WaitForExit(budget) plus
#   Kill($true) is the timeout twin, and rc 124 - the child's own, or the
#   timeout's - is what triggers the banner, exactly as bash tests $? -eq 124.
#
#   PER-CHILD ENVIRONMENT. The bash twin sets a variable on the command itself
#   (`FM_BOOTSTRAP_DETECT_ONLY=1 fm-bootstrap.sh`), which scopes it to exactly
#   that child. PowerShell has no such form: $env: assignment is PROCESS-wide
#   and would leak into every later child in this digest. Invoke-FmChildScript
#   below sets, invokes, and RESTORES (removing what was unset before, via
#   [NullString]::Value - a bare $null SETS an empty string instead).
#
#   `2>&1` CAPTURE. Invoke-FmScript returns the two streams separately, on
#   purpose. The bash twin merges them, and the digest prints the merged text,
#   so each capture site concatenates stdout then stderr and then strips
#   trailing newlines the way command substitution does. The harvest and
#   supervision calls are passthrough sites: bash streams them unmerged, so
#   this prints their raw stdout then raw stderr without trimming.
#
#   PRINTED PATHS ARE POSIX (docs/powershell-port.md contract 3). Everything
#   this digest prints - the home banner, status-log paths, the
#   fm-public-followup pointers, the tasks-axi ready pointer - is what an agent
#   copies into a follow-up command that may run in either world, and the bash
#   twin prints /f/... form. Paths this script READS stay native for .NET.
#
# INLINED LIBRARY: Invoke-FmTraceContextSessionStart below is a port of
# fm_trace_context_session_start (plus its two private helpers) from
# bin/fm-trace-context-lib.sh, inlined because that library has no .psm1 twin
# yet. Remove the inline copy when bin/fm-trace-context-lib.psm1 lands.
#
# EXECUTE EDGES THAT STAY BASH: fm-startup-network has no .ps1 twin and is
# invoked through Invoke-FmScript, which falls back to the .sh under Git Bash.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-line-cap-lib.psm1')

# Both captured at SCRIPT scope, not inside the Invoke-FmMain block: inside
# that block `$args` would resolve to the BLOCK's own (empty) argument array,
# and $PSCommandPath is equally a property of the script, which the runtime
# bound needs verbatim to re-invoke this exact file.
$fmArgv = @($args)
$fmScriptPath = $PSCommandPath

$script:FmRule = '================================================================================'
$script:FmSubrule = '--------------------------------------------------------------------------------'

# The digest's banner glyphs, built from code points rather than literals so
# the file stays pure ASCII: U+25CF BLACK CIRCLE and 71 x U+2501 BOX DRAWINGS
# HEAVY HORIZONTAL, matching the bash BAR literal byte for byte.
$script:FmDot = [string][char]0x25CF
$script:FmBar = $script:FmDot + [string]::new([char]0x2501, 71)

# The ordered stage list is the contract behind the truncation banner: the
# child names the stage it is entering, and the parent reports every stage at
# or after that one as never emitted. Keep it in the exact order the digest
# prints (bash twin: SESSION_START_STAGES).
$script:FmSessionStartStages = 'lock bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

# stage(): breadcrumb for the parent's truncation banner. Overwrites the file
# with the one current stage name; every failure is swallowed, exactly like
# `printf '%s\n' "$1" > "$FILE" 2>/dev/null || true`.
function Write-FmStage {
    param([Parameter(Mandatory)][string]$Name)
    $stageFile = Get-FmEnv 'FM_SESSION_START_STAGE_FILE' ''
    if ([string]::IsNullOrEmpty($stageFile)) { return }
    try {
        [System.IO.File]::WriteAllText((ConvertTo-FmNativePath $stageFile), "$Name`n",
            [System.Text.UTF8Encoding]::new($false))
    } catch { $null = $_ }
}

# Render the --help text by reading this file's own header: skip line 1 (the
# title, standing in for bash's shebang), strip '#' plus at most one space,
# stop at the first non-comment line (the blank line above the port notes).
function Show-FmSessionStartUsage {
    param([Parameter(Mandatory)][string]$Path)
    $lines = (Get-FmFileLines $Path)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
        $body = $line.Substring(1)
        if ($body.StartsWith(' ', [System.StringComparison]::Ordinal)) { $body = $body.Substring(1) }
        Write-FmOut $body
    }
}

function Write-FmSection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)
    Write-FmRaw "`n$script:FmRule`n$Title`n$script:FmRule`n"
}

function Write-FmSubsection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)
    Write-FmRaw "`n$Title`n$script:FmSubrule`n"
}

# The `$(cmd 2>&1)` twin: merged streams, trailing newlines stripped.
function Get-FmMergedOutput {
    param([Parameter(Mandatory)][hashtable]$Result)
    return ($Result.StdOut + $Result.StdErr).TrimEnd("`n")
}

# Run a sibling with per-child environment, then restore. See the header note.
# The restore distinguishes previously-unset from previously-empty: a saved
# $null must REMOVE the variable, and [Environment]::SetEnvironmentVariable
# binds a bare $null as '' - only [NullString]::Value actually removes.
function Invoke-FmChildScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string]$BinDir
    )
    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    try {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
        return (Invoke-FmScript -Name $Name -Arguments $Arguments -BinDir $BinDir)
    } finally {
        foreach ($key in $saved.Keys) {
            if ($null -eq $saved[$key]) {
                [Environment]::SetEnvironmentVariable($key, [NullString]::Value)
            } else {
                [Environment]::SetEnvironmentVariable($key, $saved[$key])
            }
        }
    }
}

# print_file_or_absent: full contents under a labeled subsection, or an explicit
# ABSENT marker. Absence is semantically meaningful for every one of these files
# (captain.md absent = firstmate repo built-in defaults, projects.md absent =
# rebuild from clones - AGENTS.md section 3) and must never be confused with an
# empty-but-present file, so the two cases print differently.
function Write-FmFileOrAbsent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    Write-FmSubsection $Label
    $native = ConvertTo-FmNativePath $Path
    if ([System.IO.File]::Exists($native)) {
        $text = Get-FmFileText $native
        if ($text.Length -gt 0) {
            # `cat` - byte-for-byte, including a missing final newline.
            Write-FmRaw $text
        } else {
            Write-FmOut '(present, empty)'
        }
    } else {
        Write-FmOut 'ABSENT'
    }
}

# `tail -n <n>` on a file whose last line may lack its terminator. This returns
# exactly the bytes `tail` would emit - the terminator is carried with each unit
# rather than re-added on join, so an unterminated last line stays unterminated
# HERE. Whether the consumer then terminates it is the CONSUMER's contract:
# Write-FmStatusTail feeds this through the read-loop/fm_cap_line rule, which
# does terminate it, exactly as the bash twin's pipeline does.
function Get-FmTailText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Count
    )
    # `tail -n 0` emits nothing; a slice would misread the empty request.
    if ($Count -le 0) { return '' }
    $text = Get-FmFileText $Path
    if ($text.Length -eq 0) { return '' }
    $parts = @($text.Split("`n"))
    $units = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -lt $parts.Count - 1) {
            $units.Add($parts[$i] + "`n")
        } elseif ($parts[$i] -ne '') {
            $units.Add($parts[$i])
        }
    }
    if ($units.Count -eq 0) { return '' }
    $start = [Math]::Max(0, $units.Count - $Count)
    return -join $units[$start..($units.Count - 1)]
}

# `for f in "$DIR"/*.<ext>` - sorted, and DOT-PREFIXED LEAVES EXCLUDED.
# Both halves matter: a bash glob never matches a leading dot, and state/ is
# full of dot-prefixed internals (.wake-queue, .pr-check-quarantine, the watcher
# records), so a naive enumeration would sweep records the bash twin never sees.
# The extension is re-checked because .NET's search pattern can match longer
# extensions through 8.3 aliasing.
function Get-FmDigestGlob {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Extension
    )
    $native = ConvertTo-FmNativePath $Directory
    $found = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($native, "*$Extension")) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($leaf.StartsWith('.')) { continue }
        if (-not $leaf.EndsWith($Extension, [System.StringComparison]::Ordinal)) { continue }
        $found.Add($file)
    }
    $found.Sort([System.StringComparer]::Ordinal)
    return @($found)
}

function Write-FmStatusTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrintPath,
        [Parameter(Mandatory)][string]$Count
    )
    # The count is PRINTED as the raw string the environment supplied, exactly
    # as the bash twin prints "$STATUS_TAIL": a caller who set 05 sees 05. The
    # cap is printed as a NUMBER from its one owner, never re-typed here.
    Write-FmOut ("status tail (last $Count line(s), each capped at $(Get-FmLineCapDefault) characters, " +
        "wake-EVENT history, not current state; full log: $PrintPath):")
    # A crewmate writes its own status lines, so their length is unbounded: one
    # observed line ran 865 characters. Cap each one the way the wake digest's
    # OPEN DECISIONS section does; the lede carries the state word and the key,
    # and the full log path above reaches the rest.
    #
    # The bash twin feeds `tail` into `while IFS= read -r line || [ -n "$line" ]`
    # and prints each line through fm_cap_line, which ALWAYS terminates with LF.
    # So a status file whose last line lacks its terminator gains one here - the
    # raw tail text is no longer emitted verbatim, and re-splitting it is
    # therefore correct rather than an added newline. The final empty field a
    # trailing LF produces is not a line the read loop ever sees.
    $tail = Get-FmTailText -Path $Path -Count ([int]$Count)
    if ($tail.Length -eq 0) { return }
    $lines = @($tail.Split("`n"))
    $last = $lines.Count - 1
    for ($i = 0; $i -le $last; $i++) {
        if ($i -eq $last -and $lines[$i] -ceq '') { break }
        Write-FmCappedLine -Line $lines[$i]
    }
}

function Write-FmBacklogPointer {
    Write-FmOut 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.'
}

# The awk twin. `state` PERSISTS across lines, and a heading that is not one of
# the three known sections sets it EMPTY - so items under an unknown heading are
# counted by neither branch and the heading itself is not printed. The Done
# heading is recognized so its items are skipped, never printed. A queued title
# line whose own text already marks it held or blocked (the tasks-axi markdown
# backend's "(hold: ...)", "(hold-kind: ...)", "blocked-by: ...") is ALWAYS
# kept; only the plain queued listing is bounded by the limit.
function Write-FmBacklogManualCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Limit
    )
    Write-FmOut ("compact backlog listing ($Reason; done rows omitted; every in-flight, held, and blocked " +
        "title line kept; other queued bounded to $Limit; indented task bodies omitted)")
    $max = [int]$Limit
    $sectionState = ''
    $inFlight = 0
    $doneTotal = 0
    $queuedTotal = 0
    $gated = 0
    $plainShown = 0
    foreach ($line in (Get-FmFileLines $Path)) {
        if ($line -cmatch '^##[ \t\v\f\r]+') {
            $heading = ($line -creplace '^##[ \t\v\f\r]+', '') -creplace '[ \t\v\f\r]+$', ''
            $sectionState = switch -CaseSensitive ($heading) {
                'In flight' { 'in_flight' }
                'Queued' { 'queued' }
                'Done' { 'done' }
                default { '' }
            }
            if ($sectionState -ne '' -and $sectionState -ne 'done') { Write-FmOut $line }
            continue
        }
        if ($sectionState -ceq 'in_flight' -and $line -cmatch '^[-*][ \t\v\f\r]+') {
            $inFlight++
            Write-FmOut $line
            continue
        }
        if ($sectionState -ceq 'done' -and $line -cmatch '^[-*][ \t\v\f\r]+') {
            $doneTotal++
            continue
        }
        if ($sectionState -ceq 'queued' -and $line -cmatch '^[-*][ \t\v\f\r]+') {
            $queuedTotal++
            # Bracket expression rather than a backslash escape, matching the
            # bash MANUAL_KEEP_RE and its awk -v rationale.
            if ($line -cmatch '[(]hold|blocked-by:') {
                $gated++
                Write-FmOut $line
                continue
            }
            if ($plainShown -lt $max) {
                $plainShown++
                Write-FmOut $line
            }
            continue
        }
    }
    $plainTotal = $queuedTotal - $gated
    if (($inFlight + $queuedTotal + $doneTotal) -eq 0) {
        Write-FmOut '(no backlog item title lines found)'
    } else {
        Write-FmOut ('(shown {0} in-flight, {1} held or blocked queued, {2} of {3} other queued title line(s); {4} done row(s) omitted)' -f `
            $inFlight, $gated, $plainShown, $plainTotal, $doneTotal)
        if ($plainTotal -gt $plainShown) {
            Write-FmOut ('({0} more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)' -f `
                ($plainTotal - $plainShown))
        }
    }
}

# strip_axi_help: tasks-axi closes every listing with its own help block; this
# section prints one equivalent pointer of its own, so the per-group help
# blocks stop at their `help[` header. The input is the $()-captured (trailing
# newlines stripped) listing; `printf '%s\n'` re-adds exactly one newline, so
# even an EMPTY capture yields one empty output line, reproduced here.
function Get-FmAxiHelpStripped {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($line in @($Text.Split("`n"))) {
        if ($line -cmatch '^help\[') { break }
        [void]$builder.Append($line).Append("`n")
    }
    return $builder.ToString()
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly. Note the awk twin's
# `exit` still runs its END block, so the disclosure prints even when a help
# header cut the scan short - the loop break below falls through the same way.
function Write-FmReadyQueuedBounded {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ready,
        [Parameter(Mandatory)][string]$PrintPath,
        [Parameter(Mandatory)][string]$Limit
    )
    $max = [int]$Limit
    $rows = $false
    $total = 0
    $shown = 0
    foreach ($line in @($Ready.Split("`n"))) {
        if ($line -cmatch '^help\[') { break }
        if ($line -cmatch '^ready\[') {
            $rows = $true
            Write-FmOut $line
            continue
        }
        if ($rows -and $line -cmatch '^[ \t\v\f\r]') {
            $total++
            if ($shown -lt $max) {
                Write-FmOut $line
                $shown++
            }
            continue
        }
        $rows = $false
        Write-FmOut $line
    }
    if ($total -gt 0) {
        Write-FmOut ('(shown {0} of {1} ready queued item(s))' -f $shown, $total)
        if ($total -gt $shown) {
            Write-FmOut ('({0} more queued - tasks-axi ready --file {1})' -f ($total - $shown), $PrintPath)
        }
    }
}

# The four-listing tasks-axi rendering: in-flight, held, and blocked rows in
# full, ready queued bounded. The groups are the tool's own filters, so this
# script never reimplements task state; they can overlap, because an in-flight
# item that is also held appears under both. The first failing listing aborts
# to the manual fallback with the tool's own message.
function Write-FmBacklogTasksAxiCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrintPath,
        [Parameter(Mandatory)][string]$Limit
    )
    $backlogFields = 'blocked_by,hold_kind,hold_reason'
    $nativePath = ConvertTo-FmNativePath $Path
    $cmd = Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $err = ''
    $inFlight = ''
    $held = ''
    $blocked = ''
    $ready = ''
    if ($null -eq $cmd) {
        # Only reachable when the tool vanished between the availability probe
        # and this call; bash surfaces its shell's command-not-found text here.
        $err = 'tasks-axi: not found'
    } else {
        $groups = @(
            @('list', '--file', $nativePath, '--state', 'in_flight', '--fields', $backlogFields),
            @('list', '--file', $nativePath, '--state', 'held', '--fields', $backlogFields),
            @('list', '--file', $nativePath, '--state', 'queued', '--blocked', '--fields', $backlogFields),
            @('ready', '--file', $nativePath)
        )
        for ($g = 0; $g -lt $groups.Count; $g++) {
            $result = Invoke-FmTool -FilePath $cmd.Source -Arguments $groups[$g]
            $merged = ($result.StdOut + $result.StdErr).TrimEnd("`n")
            if (-not $result.Ok) {
                $err = $merged
                break
            }
            switch ($g) {
                0 { $inFlight = $merged }
                1 { $held = $merged }
                2 { $blocked = $merged }
                3 { $ready = $merged }
            }
        }
        if ($err -eq '') {
            Write-FmOut ("compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and " +
                "blocked row shown in full; ready queued bounded to $Limit; task bodies omitted)")
            Write-FmRaw "`nin flight:`n"
            Write-FmRaw (Get-FmAxiHelpStripped $inFlight)
            Write-FmRaw "`nheld (captain- or time-gated; an in-flight item that is also held appears in both groups):`n"
            Write-FmRaw (Get-FmAxiHelpStripped $held)
            Write-FmRaw "`nblocked queued:`n"
            Write-FmRaw (Get-FmAxiHelpStripped $blocked)
            Write-FmRaw "`nready queued (dispatchable now):`n"
            Write-FmReadyQueuedBounded -Ready $ready -PrintPath $PrintPath -Limit $Limit
            return
        }
    }
    Write-FmOut 'tasks-axi compact listing failed; falling back to title-line rendering.'
    Write-FmOut $err
    Write-FmBacklogManualCompact -Path $Path -Reason 'fallback' -Limit $Limit
}

function Write-FmBacklogCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Limit,
        [Parameter(Mandatory)][string]$PrintPath
    )
    Write-FmSubsection $Label
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) {
        if ((Get-FmFileText $Path).Length -gt 0) {
            if (Test-FmTasksAxiBackendAvailable $ConfigDir) {
                Write-FmBacklogTasksAxiCompact -Path $Path -PrintPath $PrintPath -Limit $Limit
            } elseif (Test-FmBacklogBackendManual $ConfigDir) {
                Write-FmBacklogManualCompact -Path $Path -Reason 'manual backend' -Limit $Limit
            } else {
                Write-FmBacklogManualCompact -Path $Path -Reason 'tasks-axi unavailable or incompatible' -Limit $Limit
            }
            Write-FmBacklogPointer
        } else {
            Write-FmOut '(present, empty)'
        }
    } else {
        Write-FmOut 'ABSENT'
    }
}

# hash_file: shasum -a 256, else sha256sum, else cksum. When either sha tool is
# present the digest is computed IN-PROCESS - the bytes and therefore the
# "sha256:<hex>" line are identical, and this avoids a child process on a host
# where a fork costs 0.36-3.1s. cksum has no in-process equivalent worth
# writing, so that last fallback still shells out. A missing file or a host with
# none of the three yields '' , which is what `$(hash_file ... || printf '')`
# leaves the caller.
function Get-FmDigestFileHash {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    if ((Test-FmCommand 'shasum') -or (Test-FmCommand 'sha256sum')) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([System.IO.File]::ReadAllBytes($native))
        } finally {
            $sha.Dispose()
        }
        $builder = [System.Text.StringBuilder]::new('sha256:')
        foreach ($b in $bytes) { [void]$builder.Append($b.ToString('x2')) }
        return $builder.ToString()
    }
    if (-not (Test-FmCommand 'cksum')) { return '' }
    $result = Invoke-FmTool -FilePath 'cksum' -Arguments @($native)
    if (-not $result.Ok) { return '' }
    $fields = @($result.StdOut.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 2) { return '' }
    return "cksum:$($fields[0]):$($fields[1])"
}

function Test-FmPiExtensionLoaded {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Lock
    )
    if ([string]::IsNullOrEmpty($ExpectedVersion)) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Marker))) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Lock))) { return $false }
    $markerLines = (Get-FmFileLines $Marker)
    $lockLines = (Get-FmFileLines $Lock)
    # `sed -n '1p'` / `sed -n '2p'` on a short file print nothing.
    $markerVersion = if ($markerLines.Count -ge 1) { $markerLines[0] } else { '' }
    $markerPid = if ($markerLines.Count -ge 2) { $markerLines[1] } else { '' }
    $lockPid = if ($lockLines.Count -ge 1) { $lockLines[0] } else { '' }
    if ([string]::IsNullOrEmpty($markerPid)) { return $false }
    return (($markerVersion -ceq $ExpectedVersion) -and ($markerPid -ceq $lockPid))
}

# --- inlined from bin/fm-trace-context-lib.sh (see the header note) ----------

# fm_trace_context_session_lock: the pid that owns the effective-state file's
# home, or '' when the adjacent session lock is absent or malformed. bash reads
# the first line with `IFS= read -r`, which SUCCEEDS only on a \n-terminated
# line, so an unterminated lock file fails the check here too.
function Get-FmTraceContextSessionLock {
    param([Parameter(Mandatory)][string]$EffectiveFile)
    $native = ConvertTo-FmNativePath $EffectiveFile
    $stateDir = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($stateDir)) { $stateDir = '.' }
    $lockPath = Join-Path $stateDir '.lock'
    if (-not [System.IO.File]::Exists($lockPath)) { return '' }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($lockPath) } catch { return '' }
    $nl = $text.IndexOf("`n")
    if ($nl -lt 0) { return '' }
    $lockPid = $text.Substring(0, $nl)
    if ($lockPid -cnotmatch '^[0-9]+$') { return '' }
    if ([long]$lockPid -le 1) { return '' }
    return $lockPid
}

# fm_trace_context_session_start: resolve config/trace-context plus
# FM_TRACE_CONTEXT once and atomically publish the normalized on/off decision
# bound to the locked home session. Every failure path removes the effective
# file so a stale on decision can never reactivate; always returns silently.
function Invoke-FmTraceContextSessionStart {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$EffectiveFile
    )
    $nativeEffective = ConvertTo-FmNativePath $EffectiveFile
    $lockPid = Get-FmTraceContextSessionLock $EffectiveFile
    if ($lockPid -eq '') {
        try { [System.IO.File]::Delete($nativeEffective) } catch { $null = $_ }
        return
    }
    # fm_trace_context_enabled: a non-empty env value is an explicit override;
    # unset OR empty defers to the presence of config/trace-context.
    $value = 'off'
    $override = Get-FmEnv 'FM_TRACE_CONTEXT' ''
    if (-not [string]::IsNullOrEmpty($override)) {
        switch ($override.ToLowerInvariant()) {
            '1' { $value = 'on' }
            'on' { $value = 'on' }
            'true' { $value = 'on' }
            'yes' { $value = 'on' }
        }
    } elseif ([System.IO.File]::Exists((Join-Path (ConvertTo-FmNativePath $ConfigDir) 'trace-context'))) {
        $value = 'on'
    }
    if (-not (Set-FmFileTextAtomic -Path $EffectiveFile -Text "$lockPid $value`n" -NoNewline)) {
        try { [System.IO.File]::Delete($nativeEffective) } catch { $null = $_ }
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    # --- arguments, ahead of the runtime bound: --help and a usage error must
    # answer from the parent itself, never re-exec.
    $reemit = 0
    foreach ($arg in $fmArgv) {
        $argText = [string]$arg
        if ($argText -ceq '--reemit') {
            $reemit = 1
        } elseif ($argText -ceq '-h' -or $argText -ceq '--help') {
            Show-FmSessionStartUsage -Path $fmScriptPath
            Exit-FmScript 0
        } else {
            Write-FmErr "fm-session-start: unknown argument: $argText"
            Write-FmErr 'usage: fm-session-start.sh [--reemit]'
            Exit-FmScript 2
        }
    }

    # --- 0. runtime bound ----------------------------------------------------
    # When FM_SESSION_START_STAGE_FILE is unset/empty this process is the
    # PARENT: it re-invokes this exact file as a bounded child with the
    # variable set, streams the child's output through its own inherited
    # stdio, and on rc 124 prints the truncation banner. The child records the
    # stage it is entering in that file; the parent never recurses.
    if ([string]::IsNullOrEmpty((Get-FmEnv 'FM_SESSION_START_STAGE_FILE' ''))) {
        $budget = Get-FmEnv 'FM_SESSION_START_TIMEOUT' '120'
        # A non-positive or non-numeric budget is not a budget (`timeout 0`
        # disables the deadline outright), so an unusable value falls back to
        # the default rather than silently removing the bound.
        if ($budget -cnotmatch '^[0-9]+$' -or $budget -ceq '0') { $budget = '120' }
        # mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX"
        $stageFile = ''
        try {
            $tmpBase = Get-FmEnv 'TMPDIR' ''
            $tmpDir = if ([string]::IsNullOrEmpty($tmpBase)) {
                [System.IO.Path]::GetTempPath()
            } else {
                ConvertTo-FmNativePath $tmpBase
            }
            $candidate = Join-Path $tmpDir ('fm-session-start-stage.' + [System.IO.Path]::GetRandomFileName())
            [System.IO.File]::WriteAllText($candidate, '', [System.Text.UTF8Encoding]::new($false))
            $stageFile = $candidate
        } catch { $stageFile = '' }
        if ([string]::IsNullOrEmpty($stageFile)) {
            # Without a breadcrumb the bound still holds; only the banner's
            # precision is lost, so the child still runs bounded. The value
            # must stay NON-EMPTY - it is also the child-branch flag.
            $stageFile = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        }
        $selfExe = [Environment]::ProcessPath
        if ([string]::IsNullOrEmpty($selfExe)) { $selfExe = 'pwsh' }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $selfExe
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($fmScriptPath)
        foreach ($arg in $fmArgv) { $psi.ArgumentList.Add([string]$arg) }
        # No redirection, deliberately: the child inherits this process's
        # stdout/stderr so the digest STREAMS - everything emitted before the
        # bound was hit is already delivered when the child is killed.
        $psi.UseShellExecute = $false
        $psi.Environment['FM_SESSION_START_STAGE_FILE'] = $stageFile
        $sessionStartRc = 0
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $budgetMs = [long]$budget * 1000
            if ($budgetMs -gt [int]::MaxValue) { $budgetMs = [int]::MaxValue }
            if ($proc.WaitForExit([int]$budgetMs)) {
                $sessionStartRc = $proc.ExitCode
            } else {
                # Kill the whole tree, then reap: the detached network worker
                # survives in its own process group/lineage, exactly as the
                # bash `timeout` process-group kill leaves it running.
                try { $proc.Kill($true) } catch { $null = $_ }
                try { $proc.WaitForExit() } catch { $null = $_ }
                $sessionStartRc = 124
            }
        } finally {
            $proc.Dispose()
        }
        if ($sessionStartRc -eq 124) {
            $lastStage = ''
            try {
                $lastStage = ([System.IO.File]::ReadAllText((ConvertTo-FmNativePath $stageFile))).TrimEnd("`n")
            } catch { $lastStage = '' }
            if ([string]::IsNullOrEmpty($lastStage)) { $lastStage = 'unknown' }
            # awk '$0 == from {seen = 1} seen': every stage at or after the
            # recorded one, joined with single spaces, no trailing space.
            $stages = $script:FmSessionStartStages.Split(' ')
            $from = [Array]::IndexOf($stages, $lastStage)
            $pending = ''
            if ($from -ge 0) { $pending = (@($stages[$from..($stages.Count - 1)]) -join ' ') }
            if ([string]::IsNullOrEmpty($pending)) {
                $pending = '(unknown - the digest may be incomplete anywhere)'
            }
            $dot = $script:FmDot
            Write-FmRaw "`n$($script:FmBar)`n"
            Write-FmOut "$dot  STARTUP TRUNCATED - SESSION START HIT ITS ${budget}s RUNTIME BOUND"
            Write-FmOut "$dot  It stopped during the `"$lastStage`" stage, so everything above is COMPLETE"
            Write-FmOut "$dot  only up to that point."
            Write-FmOut "$dot  RECONCILE these stages before acting on anything they would have shown:"
            Write-FmOut "$dot    $pending"
            Write-FmOut "$dot  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates"
            Write-FmOut "$dot  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that"
            Write-FmOut "$dot  cannot finish inside the bound is a fleet problem, not a reporting detail."
            Write-FmOut $script:FmBar
        }
        try { [System.IO.File]::Delete((ConvertTo-FmNativePath $stageFile)) } catch { $null = $_ }
        Exit-FmScript 0
    }

    # --- the bounded child: everything below is the digest itself ------------
    $ctx = Get-FmContext $PSScriptRoot
    $binDir = $ctx.ScriptRoot
    $state = $ctx.State
    $data = $ctx.Data
    $config = $ctx.Config
    $printRoot = ConvertTo-FmPosixPath $ctx.Root
    $printHome = $ctx.PosixHome
    $printState = ConvertTo-FmPosixPath $state
    $printData = ConvertTo-FmPosixPath $data
    $completionFile = Join-Path $state '.session-start-complete'

    # `$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)`: stderr
    # discarded; on failure whatever it printed gains a trailing 'unknown';
    # command substitution strips the trailing newline.
    $harnessProbe = Invoke-FmScript -Name 'fm-harness' -BinDir $binDir
    $primaryHarness = if ($harnessProbe.Ok) {
        $harnessProbe.StdOut.TrimEnd("`n")
    } else {
        $harnessProbe.StdOut + 'unknown'
    }

    # One tasks-axi compatibility verdict per session start: computed here and
    # handed to the fm-bootstrap child as FM_TASKS_AXI_COMPATIBLE, collapsing
    # six probe subprocesses to three. fm-tasks-axi-lib owns both reuse layers
    # and the one-hop consumption rule.
    $tasksAxiCompatible = if (Test-FmTasksAxiCompatible) { '1' } else { '0' }

    $statusTail = Get-FmEnv 'FM_SESSION_START_STATUS_TAIL' '5'
    if ($statusTail -cnotmatch '^[0-9]+$') { $statusTail = '5' }
    $queuedLimit = Get-FmEnv 'FM_SESSION_START_QUEUED_LIMIT' '20'
    # `''|*[!0-9]*|0` - a non-numeric OR literally "0" both fall back to 20.
    if ($queuedLimit -cnotmatch '^[0-9]+$' -or $queuedLimit -ceq '0') { $queuedLimit = '20' }

    if ($reemit -eq 1) {
        Write-FmSection "SESSION START (CONTEXT RE-EMIT) - $printHome"
        Write-FmOut 'This session already took the helm at its own startup and has only lost its'
        Write-FmOut 'context. Lock ownership is re-verified and the durable records below are'
        Write-FmOut 'reprinted, but the sweeps startup already reconciled - project clone refresh,'
        Write-FmOut 'secondmate convergence and liveness, PR-check migration, pending remote handoff'
        Write-FmOut 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.'
        Write-FmOut 'Queued wakes ARE still drained: they arrived after startup and are this turn work.'
    } else {
        Write-FmSection "SESSION START - $printHome"
    }

    # --- 1. lock -------------------------------------------------------------
    Write-FmStage 'lock'
    Write-FmSubsection 'LOCK'
    $lockResult = Invoke-FmScript -Name 'fm-lock' -BinDir $binDir
    $lockOut = Get-FmMergedOutput $lockResult
    Write-FmOut $lockOut
    $readOnly = 0
    if (-not $lockResult.Ok) {
        $readOnly = 1
        $dot = $script:FmDot
        Write-FmOut $script:FmBar
        Write-FmOut "$dot  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED"
        Write-FmOut "$dot  $lockOut"
        Write-FmOut "$dot  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,"
        Write-FmOut "$dot  secondmate convergence, secondmate liveness, pending remote handoff retry,"
        Write-FmOut "$dot  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap"
        Write-FmOut "$dot  diagnostics and the rest of this read-only-safe digest still ran below."
        Write-FmOut "$dot  Operate read-only until this resolves - do not spawn, steer, merge, or"
        Write-FmOut "$dot  otherwise mutate fleet state from this session."
        Write-FmOut $script:FmBar
    }
    if ($readOnly -eq 0) {
        if ($reemit -eq 0) {
            # rm -f "$COMPLETION_FILE": a fresh startup owes a fresh record.
            try { [System.IO.File]::Delete((ConvertTo-FmNativePath $completionFile)) } catch { $null = $_ }
        }
        Invoke-FmTraceContextSessionStart -ConfigDir $config -EffectiveFile (Join-Path $state '.trace-context-effective')
        # Every network call this session start owes is launched HERE, detached
        # and bounded, so it runs concurrently with the whole digest below
        # instead of in front of it. Step 7 harvests whatever it has finished,
        # without ever waiting. --reemit passes --locked 0: this process
        # already ran the mutating sweeps at its own startup, so only the
        # read-only GitHub-auth probe is owed. A read-only session starts
        # nothing at all. --harvest-pid names THIS bounded child, the process
        # whose harvest may print the result inline (bash passes $$).
        $networkStageLocked = if ($reemit -eq 0) { '1' } else { '0' }
        $null = Invoke-FmScript -Name 'fm-startup-network' -BinDir $binDir -Arguments @(
            'start', '--locked', $networkStageLocked, '--harvest-pid', "$PID")
    }

    # --- 2. bootstrap --------------------------------------------------------
    # FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is
    # what the deferred stage above is running right now, and running it twice
    # would both re-block this digest and race the worker's sweeps against
    # themselves.
    Write-FmStage 'bootstrap'
    Write-FmSubsection 'BOOTSTRAP'
    if ($readOnly -eq 1) {
        $bootResult = Invoke-FmChildScript -Name 'fm-bootstrap' -BinDir $binDir -Environment @{
            FM_BOOTSTRAP_DETECT_ONLY = '1'
            FM_BOOTSTRAP_NETWORK     = 'skip'
            FM_TASKS_AXI_COMPATIBLE  = $tasksAxiCompatible
        }
        $bootOut = Get-FmMergedOutput $bootResult
    } elseif ($reemit -eq 1) {
        $bootResult = Invoke-FmChildScript -Name 'fm-bootstrap' -BinDir $binDir -Environment @{
            FM_BOOTSTRAP_DETECT_ONLY = '1'
            FM_BOOTSTRAP_LOCKED      = '1'
            FM_BOOTSTRAP_NETWORK     = 'skip'
            FM_TASKS_AXI_COMPATIBLE  = $tasksAxiCompatible
        }
        $bootOut = Get-FmMergedOutput $bootResult
    } else {
        # The bash runs both inside ONE command substitution, so the cleanup's
        # output precedes bootstrap's in a single buffer and its failure is
        # swallowed (`|| true`).
        $cleanupResult = Invoke-FmScript -Name 'fm-herdr-session-cleanup' -BinDir $binDir
        $bootResult = Invoke-FmChildScript -Name 'fm-bootstrap' -BinDir $binDir -Environment @{
            FM_BOOTSTRAP_NETWORK    = 'skip'
            FM_TASKS_AXI_COMPATIBLE = $tasksAxiCompatible
        }
        $combined = $cleanupResult.StdOut + $cleanupResult.StdErr + $bootResult.StdOut + $bootResult.StdErr
        $bootOut = $combined.TrimEnd("`n")
    }
    if ($bootOut.Length -gt 0) {
        Write-FmOut $bootOut
    } else {
        Write-FmOut '(silent - all good)'
    }

    # --- 3. wake-drain -------------------------------------------------------
    # Drained records are this turn's first work queue, and the drain's
    # separate OPEN DECISIONS section remains actionable even when that queue
    # is empty (AGENTS.md sections 3 and 8). The drain also runs fm-guard
    # internally on the locked path, so the tangle/watcher-liveness alarms land
    # right here too, ahead of the bulk digest below. The read-only path never
    # touches the queue because it lacks mutation authority, and another
    # session may be actively draining it. It still runs fm-guard directly with
    # non-mutating advisory text, so the same alarms surface without repair
    # commands.
    Write-FmStage 'wake-queue'
    Write-FmSubsection 'WAKE QUEUE'
    if ($readOnly -eq 1) {
        $queuePath = Join-Path $state '.wake-queue'
        $qlen = 0
        $queueText = Get-FmFileText $queuePath
        if ($queueText.Length -gt 0) {
            # `grep -c .` counts NON-EMPTY lines, not all lines.
            foreach ($line in (Get-FmFileLines $queuePath)) {
                if ($line -ne '') { $qlen++ }
            }
        }
        Write-FmOut "skipped (read-only session) - $qlen record(s) remain queued because this session lacks verified fleet-lock ownership."
        $guardResult = Invoke-FmChildScript -Name 'fm-guard' -BinDir $binDir `
            -Environment @{ FM_GUARD_READ_ONLY = '1' }
        $guardOut = Get-FmMergedOutput $guardResult
        if ($guardOut.Length -gt 0) { Write-FmOut $guardOut }
    } else {
        $drainResult = Invoke-FmScript -Name 'fm-wake-drain' -BinDir $binDir
        $drainOut = Get-FmMergedOutput $drainResult
        if ($drainOut.Length -gt 0) {
            Write-FmOut $drainOut
        } else {
            Write-FmOut '(no queued wakes)'
        }
    }

    # --- 4. supervision operating instructions ------------------------------
    Write-FmStage 'supervision-instructions'
    $afkPresent = 0
    $afkPath = ConvertTo-FmNativePath (Join-Path $state '.afk')
    if ([System.IO.File]::Exists($afkPath) -or [System.IO.Directory]::Exists($afkPath)) { $afkPresent = 1 }
    $xModeEnvPath = ConvertTo-FmNativePath (Join-Path $config 'x-mode.env')
    $xModePresent = 0
    if ([System.IO.File]::Exists($xModeEnvPath)) { $xModePresent = 1 }

    if ($primaryHarness -ceq 'pi' -or $primaryHarness -ceq 'pi-signed') {
        $piExt = "$printRoot/.pi/extensions/fm-primary-pi-watch.ts"
        $piTurnendExt = "$printRoot/.pi/extensions/fm-primary-turnend-guard.ts"
        $piWatchMarker = Join-Path $state '.pi-watch-extension-loaded'
        $piTurnendMarker = Join-Path $state '.pi-turnend-extension-loaded'
        $piLock = Join-Path $state '.lock'
        $piRestartCommand = if ($primaryHarness -cne 'pi') { $primaryHarness } else { 'plain pi' }
        $piWatchVersion = Get-FmDigestFileHash (Join-Path $ctx.Root '.pi/extensions/fm-primary-pi-watch.ts')
        $piTurnendVersion = Get-FmDigestFileHash (Join-Path $ctx.Root '.pi/extensions/fm-primary-turnend-guard.ts')
        if ((-not (Test-FmPiExtensionLoaded $piWatchMarker $piWatchVersion $piLock)) -or
            (-not (Test-FmPiExtensionLoaded $piTurnendMarker $piTurnendVersion $piLock))) {
            Write-FmOut ("PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart $piRestartCommand so $piTurnendExt and $piExt auto-load for turn-end guard and background wake coverage; use -e $piTurnendExt -e $piExt only if project hooks are not trusted")
        }
    }

    $superResult = Invoke-FmScript -Name 'fm-supervision-instructions' -BinDir $binDir -Arguments @(
        '--harness', $primaryHarness,
        '--read-only', [string]$readOnly,
        '--afk', [string]$afkPresent,
        '--x-mode', [string]$xModePresent
    )
    Write-FmRaw $superResult.StdOut
    if ($superResult.StdErr.Length -gt 0) { Write-FmRaw $superResult.StdErr }

    # --- 5. read-once contract ----------------------------------------------
    # Ahead of the two digests it governs, not after them: a truncated tail is
    # exactly what drops a closing reminder, and this contract is what stops
    # the next turn from re-reading everything the digest just printed. Because
    # it arrives BEFORE its subject, it also names the one condition that voids
    # it - a stage that never ran, which the truncation banner names by stage.
    Write-FmStage 'read-once'
    Write-FmSection 'READ-ONCE CONTRACT'
    Write-FmOut @'
Everything below is printed in full for this session start: every state/*.meta,
a compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (tasks-axi show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
'@

    # --- 6. fleet-state digest ----------------------------------------------
    # Before CONTEXT: see this file's ORDERING note. Live fleet identity is
    # what a truncated tail must never take.
    Write-FmStage 'fleet-state'
    Write-FmSection 'FLEET STATE'
    Write-FmBacklogCompact -Path (Join-Path $data 'backlog.md') -Label 'data/backlog.md' `
        -ConfigDir $config -Limit $queuedLimit -PrintPath "$printData/backlog.md"

    Write-FmSubsection 'Work under way (state/*.meta)'
    $metaFound = $false
    foreach ($meta in (Get-FmDigestGlob $state '.meta')) {
        $metaFound = $true
        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
        Write-FmRaw "`n--- $id ---`n"
        Write-FmRaw (Get-FmFileText $meta)

        $window = Get-FmMetaValue -MetaPath $meta -Key 'window'
        $target = Get-FmBackendTargetOfMeta $meta
        if (-not [string]::IsNullOrEmpty($window)) {
            $backend = Get-FmBackendOfMeta $meta
            $probeTarget = if ([string]::IsNullOrEmpty($target)) { $window } else { $target }
            if (Test-FmBackendTargetExists $backend $probeTarget "fm-$id") {
                Write-FmOut "endpoint: alive (backend=$backend window=$window)"
            } else {
                Write-FmOut "endpoint: dead (backend=$backend window=$window)"
            }
        } else {
            Write-FmOut 'endpoint: unknown (no window recorded)'
        }

        $statusPath = Join-Path $state "$id.status"
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $statusPath))) {
            Write-FmStatusTail -Path $statusPath -PrintPath "$printState/$id.status" -Count $statusTail
        } else {
            Write-FmOut "status tail: (no status file yet: $printState/$id.status)"
        }
    }
    if (-not $metaFound) { Write-FmOut '(none)' }

    Write-FmSubsection 'Orphan status logs (state/*.status without matching .meta)'
    $orphanFound = $false
    foreach ($status in (Get-FmDigestGlob $state '.status')) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($status)
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $state "$id.meta")))) { continue }
        $orphanFound = $true
        Write-FmRaw "`n--- $id ---`n"
        Write-FmStatusTail -Path $status -PrintPath "$printState/$id.status" -Count $statusTail
    }
    if (-not $orphanFound) { Write-FmOut '(none)' }

    Write-FmSubsection 'AFK'
    if ($afkPresent -eq 1) {
        Write-FmOut 'present - away-mode supervision is active; the daemon owns the watcher.'
    } else {
        Write-FmOut 'absent'
    }

    # Public commitments made through the myfirstmate relay. A promise to reply
    # in a public thread must survive compaction and restart, so it is surfaced
    # from disk here rather than from conversation memory. A home that never
    # opted into the relay runs one existence test, prints no subsection, and
    # never reaches fm-public-followup.
    if ((Test-FmPfRelayActive $ctx.Home) -and
        ((Test-FmPfHasRegistration $state) -or (Test-FmPfHasEvent $state))) {
        $pfResult = Invoke-FmScript -Name 'fm-public-followup' -BinDir $binDir -Arguments @('pending')
        $publicFollowup = if ($pfResult.Ok) { $pfResult.StdOut.TrimEnd("`n") } else { '' }
        if ($publicFollowup.Length -gt 0) {
            Write-FmSubsection 'Public commitments awaiting delivery'
            Write-FmOut $publicFollowup
            Write-FmRaw "`nEach line is a public reply this home still owes. Reconcile terminal results with`n"
            Write-FmOut "$printRoot/bin/fm-public-followup.sh consume, then deliver a ready one with"
            Write-FmOut "$printRoot/bin/fm-public-followup.sh deliver <id>. Load fmx-respond for the procedure."
        }
    }

    # --- 7. network checks ---------------------------------------------------
    # Deliberately here and not later: these lines are actionable, and the
    # section after this one is the curated memory a truncated tail is meant to
    # take first. Deliberately here and not earlier: this is the last point in
    # the digest, so the worker started at step 1 has had the whole composition
    # above to finish in. It is a NON-BLOCKING read either way - whatever the
    # worker has published by now is printed, and whatever it has not is named
    # as not yet confirmed.
    Write-FmStage 'network-checks'
    Write-FmSection 'NETWORK CHECKS'
    if ($readOnly -eq 1) {
        Write-FmOut 'skipped (read-only session) - GitHub authentication, project clone refresh,'
        Write-FmOut 'secondmate liveness and convergence, and pending handoff delivery were not run.'
        Write-FmOut 'They need the fleet lock, and this session must not spawn, steer, or merge, so it'
        Write-FmOut 'has no action they would gate. The session holding the lock runs them.'
    } else {
        # `... harvest --pid $$ 2>&1 || true` - a passthrough, not a $()
        # capture, so the raw streams print untrimmed and the exit code is
        # ignored.
        $harvestResult = Invoke-FmScript -Name 'fm-startup-network' -BinDir $binDir -Arguments @(
            'harvest', '--pid', "$PID")
        Write-FmRaw $harvestResult.StdOut
        if ($harvestResult.StdErr.Length -gt 0) { Write-FmRaw $harvestResult.StdErr }
    }

    # --- 8. context digest ---------------------------------------------------
    # Last of the bulk sections deliberately: curated memory is stable session
    # to session, already governed by config/startup-memory-budget, and
    # recoverable with one targeted read, so it is the cheapest thing for a
    # truncated tail to take (see this file's ORDERING note).
    Write-FmStage 'context'
    Write-FmSection 'CONTEXT'
    Write-FmFileOrAbsent (Join-Path $data 'projects.md') 'data/projects.md'
    Write-FmFileOrAbsent (Join-Path $data 'secondmates.md') 'data/secondmates.md'
    Write-FmFileOrAbsent (Join-Path $data 'captain.md') 'data/captain.md'
    Write-FmFileOrAbsent (Join-Path $data 'captain-shared.md') 'data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)'
    Write-FmFileOrAbsent (Join-Path $data 'learnings.md') 'data/learnings.md'

    # --- 9. closing reminder -------------------------------------------------
    Write-FmStage 'next-step'
    Write-FmSection 'NEXT STEP'
    if ($readOnly -eq 1) {
        Write-FmRaw @"
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.


"@
    } elseif ($afkPresent -eq 1) {
        Write-FmRaw @"
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.


"@
    } elseif ($xModePresent -eq 1) {
        Write-FmRaw @"
Follow the supervision operating instructions block above for harness '$primaryHarness'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.


"@
    } else {
        Write-FmRaw @"
Follow the supervision operating instructions block above for harness '$primaryHarness'.
This script never starts supervision itself.


"@
    }
    Write-FmRaw @'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
'@
    Write-FmRaw "`n"

    if ($readOnly -eq 0 -and $reemit -eq 0) {
        # `$(cat "$STATE/.lock")` strips trailing newlines; anything but pure
        # digits (including a multi-line record) empties the pid, and any
        # failure to publish the completion record is disclosed rather than
        # silently leaving the next clear to guess.
        $completionPid = (Get-FmFileText (Join-Path $state '.lock')).TrimEnd("`n")
        if ($completionPid -cnotmatch '^[0-9]+$') { $completionPid = '' }
        $recorded = $false
        if ($completionPid -ne '') {
            $recorded = Set-FmFileTextAtomic -Path $completionFile -Text "$completionPid`n" -NoNewline
        }
        if (-not $recorded) {
            Write-FmRaw "`nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.`n"
        }
    }

    Exit-FmScript 0
}
