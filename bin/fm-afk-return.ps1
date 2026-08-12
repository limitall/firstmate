# fm-afk-return.ps1 - deterministic away-mode return catch-up gate.
#
# Twin: bin/fm-afk-return.sh
#
# Usage:
#   fm-afk-return.ps1          Stop away mode, drain catch-up, and open/check gate.
#   fm-afk-return.ps1 begin    Same as the default command.
#   fm-afk-return.ps1 check    Re-drain and close the gate only after blockers resolve.
#   fm-afk-return.ps1 guard    Read-only refusal while away or catch-up is pending.
#
# `blocked:` is the crewmate protocol's firstmate-actionable verb. A live task's
# open blocked event must be remediated and closed with `resolved [key=...]`, or
# explicitly reclassified in the status stream with a durable reason, before an
# ordinary captain request may proceed. `needs-decision:` belongs to the
# configured approval authority and is deliberately not part of this blocker
# gate.
#
# The durable state/.afk-return-catchup file is written BEFORE daemon shutdown,
# so a crash between stopping, draining, and blocker handling refuses rather than
# proceeding. It retains the drained wake, buffered-escalation, and wedge-marker
# evidence until every live open blocker is closed and `check` succeeds. Repeated
# begin/check calls are idempotent.
#
# ---------------------------------------------------------------------------
# EXIT CODES ARE THE INTERFACE
#
#   0  usage, or catch-up clear
#   1  a lifecycle write failed before the gate could be seeded
#   2  invalid use
#   3  the gate refuses: away mode still active, catch-up still pending, or an
#      open blocker remains. Callers branch on 3 specifically, so it may never
#      collapse into 1.
#
# ---------------------------------------------------------------------------
# THREE MECHANICS THAT ARE LOAD-BEARING HERE
#
# 1. `guard` IS LITERALLY READ-ONLY, AND THAT IS WHY THE IMPORTS ARE LAZY.
#    bin/fm-wake-lib.psm1 resolves its context and CREATES the state directory in
#    its module body, exactly as its bash twin does at source time. The bash
#    script's `guard` arm returns BEFORE sourcing it precisely so a read-only
#    entrypoint (bin/fm-bearings-snapshot.sh) cannot materialize a state tree by
#    asking a question. The imports below therefore sit inside the mutating
#    begin/check path, not at the top of the file, and moving them up would break
#    the advertised contract silently.
#
# 2. THE CHILD SCRIPTS GO THROUGH Invoke-FmScript, NEVER A HARD-CODED EXTENSION.
#    `fm-afk-launch` and `fm-wake-drain` are EXECUTE edges (a process boundary),
#    so this file must work whether the target is still bash or already
#    converted - docs/powershell-port.md contract 7.
#
# 3. RELAYED CHILD OUTPUT IS CAPTURED, THEN WRITTEN THROUGH. The bash twin lets
#    `fm-afk-launch.sh stop` inherit both streams, and captures only
#    fm-wake-drain's stdout. Invoke-FmScript captures by default, so the launch
#    child's streams are relayed verbatim afterwards instead of inherited. The
#    bytes and the stream split are identical; only the INTERLEAVING differs
#    (the child's output arrives as one block rather than live), which is the
#    price of keeping the relay byte-exact under a redirected console. Recorded
#    here rather than normalized away.
#
# NO param() BLOCK and $args CAPTURED FIRST, for the reasons the exemplar
# bin/fm-operational-input.ps1 records.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force. -Force REMOVES the loaded module and re-runs its body, and
# fm-common's body reassigns [Console]::OutputEncoding, which REPLACES
# [Console]::Out and [Console]::In. A batch differential driver that captures a
# case through [Console]::SetOut would silently lose every case after the first.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$fmArgv = @($args)

$script:FmOrdinal = [System.StringComparison]::Ordinal

# --- context -----------------------------------------------------------------

$script:FmReturnContext = Get-FmContext -ScriptRoot $PSScriptRoot
$script:FmReturnState = $script:FmReturnContext.State
$script:FmReturnGate = "$script:FmReturnState/.afk-return-catchup"
$script:FmReturnLock = "$script:FmReturnState/.afk-return-catchup.lock"

<#
.SYNOPSIS
The usage text, one array element per line.
.DESCRIPTION
The bash twin renders this by re-reading its own comment block
(`sed -n '2,7p' | sed 's/^# \{0,1\}//'`). Reproduced literally, still naming the
.sh file, because CLI surfaces stay identical during the transition
(docs/powershell-port.md contract 4) and the differential harness compares this
stdout directly.
#>
function Get-FmReturnUsage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'fm-afk-return.sh - deterministic away-mode return catch-up gate.'
        ''
        'Usage:'
        '  fm-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.'
        '  fm-afk-return.sh begin    Same as the default command.'
        '  fm-afk-return.sh check    Re-drain and close the gate only after blockers resolve.'
    )
}

<#
.SYNOPSIS
Flatten a value into one record field (clean_field).
.DESCRIPTION
`LC_ALL=C tr '\t\r\n' '   '` - each of the three characters becomes a SPACE, one
for one, never dropped. The records here are TAB-delimited and line-oriented, so
a value carrying either separator would silently re-shape the record it lands in.
#>
function ConvertTo-FmReturnCleanField {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}

<#
.SYNOPSIS
Append one `evidence<TAB><kind><TAB><text>` record per non-empty line, deduped.
.DESCRIPTION
Twin of append_evidence. The dedupe is bash's `grep -Fqx`: a FIXED, WHOLE-LINE
match, so a record that is a prefix or a substring of an existing one is still
appended. Empty text appends nothing at all, and empty lines inside the text are
skipped - which is what keeps a drained-but-empty wake list out of the gate.
#>
function Add-FmReturnEvidence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal append helper on the twin of a bash function that writes unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive return.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Kind,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Mandatory, Position = 2)][string]$File
    )

    if ([string]::IsNullOrEmpty($Text)) { return }
    # Seeded one line at a time rather than from the function's return value:
    # a PowerShell function returning an EMPTY array yields $null at the call
    # site, and the HashSet(IEnumerable, comparer) constructor rejects null -
    # so the collection form threw on the first append to a fresh evidence file,
    # which is the ordinary case.
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($known in (Get-FmFileLines -Path $File)) { [void]$existing.Add($known) }
    $body = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    foreach ($line in @($body.Split("`n"))) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $record = "evidence`t$Kind`t" + (ConvertTo-FmReturnCleanField $line)
        if ($existing.Add($record)) { Add-FmFileLine -Path $File -Line $record }
    }
}

<#
.SYNOPSIS
The gate's existing evidence records, in order (preserve_evidence).
.DESCRIPTION
`grep '^evidence<TAB>'` over the current gate. Returned as lines rather than
written, because both callers compose them into a file they are already
building; a missing gate yields nothing, which is the normal first-entry state.
#>
function Get-FmReturnPreservedEvidence {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $kept = @()
    foreach ($line in (Get-FmFileLines -Path $script:FmReturnGate)) {
        if ($line.StartsWith("evidence`t", $script:FmOrdinal)) { $kept += $line }
    }
    return @($kept)
}

<#
.SYNOPSIS
Every live task's still-open `blocked:` event, as blocker rows.
.DESCRIPTION
Twin of scan_open_blockers. A task counts only when BOTH its metadata record and
its status log exist, so a torn-down task cannot hold the captain's return open.
The keyed fold in fm-classify-lib decides what is still open; this only filters
that fold to the firstmate-actionable verb.

Files are enumerated in ORDINAL order to match the bash glob's expansion, and
each fold line is split into exactly three fields with the remainder kept - the
`IFS=<TAB> read -r key verb summary` shape, where a summary containing tabs stays
whole rather than being truncated at the first one.
#>
function Get-FmReturnOpenBlocker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural matches the return shape and the bash name it stays greppable against: this yields the SET of open blocker rows, and the singular would read as fetch-one-blocker.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $stateNative = ConvertTo-FmNativePath -Path $script:FmReturnState
    if (-not [System.IO.Directory]::Exists($stateNative)) { return @() }
    $metas = @([System.IO.Directory]::GetFiles($stateNative, '*.meta'))
    [System.Array]::Sort($metas, [System.StringComparer]::Ordinal)

    $rows = @()
    foreach ($meta in $metas) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
        $status = "$script:FmReturnState/$id.status"
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath -Path $status))) { continue }
        $fold = Get-FmStatusOpenDecisions -Path $status
        if ([string]::IsNullOrEmpty($fold)) { continue }
        foreach ($line in @(($fold -replace "`r", '').Split("`n"))) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $field = @($line.Split("`t", 3, [System.StringSplitOptions]::None))
            $key = if ($field.Count -ge 1) { $field[0] } else { '' }
            $verb = if ($field.Count -ge 2) { $field[1] } else { '' }
            $summary = if ($field.Count -ge 3) { $field[2] } else { '' }
            if (-not [string]::Equals($verb, 'blocked', $script:FmOrdinal)) { continue }
            $rows += "blocker`t$id`t$key`t" + (ConvertTo-FmReturnCleanField $summary)
        }
    }
    return @($rows)
}

<#
.SYNOPSIS
The gate's `started` epoch, or a fresh one when it has none.
.DESCRIPTION
`awk -F '\t' '$1 == "started" { print $2; exit }'`: the FIRST such record wins,
so re-seeding an existing gate preserves when the return actually began rather
than restarting the clock on every `check`.
#>
function Get-FmReturnStarted {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($line in (Get-FmFileLines -Path $script:FmReturnGate)) {
        $field = @($line.Split("`t", 2, [System.StringSplitOptions]::None))
        if ($field.Count -ge 2 -and [string]::Equals($field[0], 'started', $script:FmOrdinal)) {
            return $field[1]
        }
    }
    return ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

<#
.SYNOPSIS
Publish gate content atomically (the mktemp + mv twin). $true on success.
#>
function Write-FmReturnGate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal publish helper on the twin of a bash function that writes unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive return.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Phase,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Body = @()
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("schema`tfm-afk-return.v1`n")
    [void]$sb.Append("started`t").Append((Get-FmReturnStarted)).Append("`n")
    [void]$sb.Append("phase`t").Append($Phase).Append("`n")
    foreach ($line in @($Body)) { [void]$sb.Append($line).Append("`n") }
    return (Set-FmFileTextAtomic -Path $script:FmReturnGate -Text $sb.ToString() -NoNewline)
}

<#
.SYNOPSIS
Render the evidence records of a file as captain-facing lines (print_evidence).
#>
function Get-FmReturnEvidenceText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $out = @()
    foreach ($line in (Get-FmFileLines -Path $Path)) {
        $field = @($line.Split("`t", 3, [System.StringSplitOptions]::None))
        if ($field.Count -lt 1 -or -not [string]::Equals($field[0], 'evidence', $script:FmOrdinal)) { continue }
        $kind = if ($field.Count -ge 2) { $field[1] } else { '' }
        $text = if ($field.Count -ge 3) { $field[2] } else { '' }
        $out += "catch-up ${kind}: $text"
    }
    return @($out)
}

<#
.SYNOPSIS
Render the blocker records of a file as captain-facing lines (print_blockers).
#>
function Get-FmReturnBlockerText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $out = @()
    foreach ($line in (Get-FmFileLines -Path $Path)) {
        $field = @($line.Split("`t", 4, [System.StringSplitOptions]::None))
        if ($field.Count -lt 1 -or -not [string]::Equals($field[0], 'blocker', $script:FmOrdinal)) { continue }
        $id = if ($field.Count -ge 2) { $field[1] } else { '' }
        $key = if ($field.Count -ge 3) { $field[2] } else { '' }
        $summary = if ($field.Count -ge 4) { $field[3] } else { '' }
        $out += "firstmate-actionable blocker: $id [key=$key] $summary"
    }
    return @($out)
}

<#
.SYNOPSIS
Drop the away session's delivery artifacts (clear_delivery_artifacts).
#>
function Clear-FmReturnDeliveryArtifact {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f` list run once the gate has cleared; a confirmation surface would diverge from the twin and stall a non-interactive return.')]
    [CmdletBinding()]
    param()

    foreach ($name in @('.subsuper-escalations', '.subsuper-escalations.since', '.subsuper-inject-wedged')) {
        $native = ConvertTo-FmNativePath -Path "$script:FmReturnState/$name"
        try { if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) } } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
The read-only refusal (return_guard). 3 = refuse, 0 = clear.
.DESCRIPTION
Never mutates anything - not the gate, not the state directory - which is what
makes it safe for ordinary read entrypoints. See mechanic 1 in the file header
for why that property depends on the import placement rather than on this
function alone.
#>
function Test-FmReturnGuard {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmReturnState/.afk")) {
        Write-FmErr 'fm-afk-return: away mode is still active; run bin/fm-afk-return.sh before ordinary captain work'
        return 3
    }
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $script:FmReturnGate)) {
        Write-FmErr 'fm-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/fm-afk-return.sh check'
        foreach ($line in @(Get-FmReturnBlockerText -Path $script:FmReturnGate)) { Write-FmErr $line }
        return 3
    }
    return 0
}

<#
.SYNOPSIS
Relay a captured child result to this process's own streams, byte for byte.
.DESCRIPTION
The bash twin's child INHERITS the streams; Invoke-FmScript captures them, so the
bytes are written through afterwards. [Console]::Error.Write is used directly
rather than Write-FmErr because the relay must add nothing - Write-FmErr appends
an LF, which would invent a newline the child never emitted. Mechanic 3 in the
file header records the one observable consequence.
#>
function Write-FmReturnRelay {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$StdOut = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StdErr = ''
    )
    if (-not [string]::IsNullOrEmpty($StdOut)) { Write-FmRaw -Text $StdOut }
    if (-not [string]::IsNullOrEmpty($StdErr)) { [Console]::Error.Write($StdErr) }
}

<#
.SYNOPSIS
Stop away mode, drain catch-up, and open or close the gate (return_reconcile).
.DESCRIPTION
Returns 0 when the captain may proceed, 3 when the gate refuses, 1 when the gate
itself could not be published. The order is the contract: shut the daemon down
while state/.afk is still present, drain the durable queue, harvest the buffered
escalation evidence, and only THEN decide - so a crash anywhere in the middle
leaves the seeded gate behind and the next call redoes the work.
#>
function Invoke-FmReturnReconcile {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $stamp = [System.IO.Path]::GetRandomFileName().Replace('.', '').Substring(0, 6)
    $evidence = "$script:FmReturnState/.afk-return-evidence.$stamp"
    $blockers = "$script:FmReturnState/.afk-return-blockers.$stamp"
    Set-FmFileText -Path $evidence -Text '' -NoNewline
    Set-FmFileText -Path $blockers -Text '' -NoNewline

    $lifecycleOk = $true
    foreach ($line in @(Get-FmReturnPreservedEvidence)) { Add-FmFileLine -Path $evidence -Line $line }

    $afkPresent = Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmReturnState/.afk")
    $recordPresent = Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmReturnState/.afk-daemon-terminal")
    if ($afkPresent -or $recordPresent) {
        $stop = Invoke-FmScript -Name 'fm-afk-launch' -Arguments @('stop')
        Write-FmReturnRelay -StdOut $stop.StdOut -StdErr $stop.StdErr
        if (-not $stop.Ok) {
            $lifecycleOk = $false
            Add-FmReturnEvidence -Kind lifecycle -Text 'away-mode shutdown failed; lifecycle state preserved for retry' -File $evidence
        }
    }

    $drain = Invoke-FmScript -Name 'fm-wake-drain'
    Write-FmReturnRelay -StdErr $drain.StdErr
    $drained = ''
    if ($drain.Ok) {
        # `drained=$(...)` - command substitution strips EVERY trailing newline.
        $drained = $drain.StdOut.TrimEnd("`n")
    } else {
        Add-FmReturnEvidence -Kind lifecycle -Text 'durable wake drain failed; retry catch-up before ordinary work' -File $evidence
        $lifecycleOk = $false
    }
    Add-FmReturnEvidence -Kind wake -Text $drained -File $evidence

    $wedgeText = Get-FmFileText -Path "$script:FmReturnState/.subsuper-inject-wedged"
    if (-not [string]::IsNullOrEmpty($wedgeText)) {
        $lines = (Get-FmFileLines -Path "$script:FmReturnState/.subsuper-inject-wedged")
        $wedge = if ($lines.Count -ge 1) { $lines[0] } else { '' }
        Add-FmReturnEvidence -Kind wedge -Text $wedge -File $evidence
    }
    $escalationText = Get-FmFileText -Path "$script:FmReturnState/.subsuper-escalations"
    if (-not [string]::IsNullOrEmpty($escalationText)) {
        Add-FmReturnEvidence -Kind escalation -Text ($escalationText.TrimEnd("`n")) -File $evidence
    }

    $blockerRows = @(Get-FmReturnOpenBlocker)
    foreach ($row in $blockerRows) { Add-FmFileLine -Path $blockers -Line $row }

    if ((-not $lifecycleOk) -or $blockerRows.Count -gt 0) {
        $body = (Get-FmFileLines -Path $evidence) + (Get-FmFileLines -Path $blockers)
        if (-not (Write-FmReturnGate -Phase 'blocked' -Body $body)) {
            Remove-FmReturnScratch -Path $evidence
            Remove-FmReturnScratch -Path $blockers
            return 1
        }
        Write-FmErr 'fm-afk-return: catch-up must finish before the captain request'
        foreach ($line in @(Get-FmReturnEvidenceText -Path $script:FmReturnGate)) { Write-FmErr $line }
        foreach ($line in @(Get-FmReturnBlockerText -Path $script:FmReturnGate)) { Write-FmErr $line }
        Write-FmErr 'fm-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/fm-afk-return.sh check'
        Remove-FmReturnScratch -Path $evidence
        Remove-FmReturnScratch -Path $blockers
        return 3
    }

    foreach ($line in @(Get-FmReturnEvidenceText -Path $evidence)) { Write-FmOut $line }
    Remove-FmReturnScratch -Path $script:FmReturnGate
    Clear-FmReturnDeliveryArtifact
    Remove-FmReturnScratch -Path $evidence
    Remove-FmReturnScratch -Path $blockers
    Write-FmOut 'fm-afk-return: catch-up clear; ordinary captain work may proceed'
    return 0
}

<#
.SYNOPSIS
`rm -f <path>`: absence is success, and a failure is never fatal.
#>
function Remove-FmReturnScratch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of `rm -f` on a file this script itself created; a confirmation surface would diverge from the twin and stall a non-interactive return.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath -Path $Path
    try { if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) } } catch { $null = $_ }
}

<#
.SYNOPSIS
The CLI body: run one command and return its exit code.
#>
function Invoke-FmReturnMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }
    $argv = @($Arguments)
    $mode = if ($argv.Count -ge 1) { [string]$argv[0] } else { 'begin' }

    if ([string]::Equals($mode, 'guard', $script:FmOrdinal)) { return (Test-FmReturnGuard) }
    if ($mode -cin @('-h', '--help', 'help')) {
        foreach ($line in @(Get-FmReturnUsage)) { Write-FmOut $line }
        return 0
    }
    if ($mode -cnotin @('begin', 'check')) {
        foreach ($line in @(Get-FmReturnUsage)) { Write-FmErr $line }
        return 2
    }

    # LAZY, and deliberately so - see mechanic 1 in the file header. Everything
    # above this line is read-only, exactly as the bash twin's `guard` arm is.
    Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
    Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1')

    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $script:FmReturnState))
    Wait-FmLock -LockPath $script:FmReturnLock
    try {
        # The fail-closed seed: written BEFORE any lifecycle mutation, so a crash
        # between here and the verdict leaves a pending gate rather than a
        # silently-returned captain.
        $seed = Write-FmReturnGate -Phase 'stopping-and-draining' -Body @(Get-FmReturnPreservedEvidence)
        if (-not $seed) { return 1 }
        return (Invoke-FmReturnReconcile)
    } finally {
        Unlock-FmLock -LockPath $script:FmReturnLock
    }
}

# UnexpectedCode 70 rather than 1, 2 or 3: this CLI documents those three, and an
# escaped exception is a DEFECT, not a documented refusal. A caller branching on
# 3 (the gate refusal) can then never absorb one silently.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmReturnMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
