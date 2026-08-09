# bin/fm-fleet-snapshot.ps1 - read-only structured fleet snapshot.
#
# Twin: bin/fm-fleet-snapshot.sh
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind and
#     hold_reason when tasks-axi emits it. They also carry normalized current_role,
#     requires_child_metadata, blocked_by_ids, unresolved_blocker_ids, and
#     captain_actionable fields. Repeated blocker tokens remain ordered; a blocker
#     resolves only when its structured record is Done, and missing ids stay open.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib's authoritative Get-FmStatusOpenDecisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory, secondmate_current, secondmate_landed, secondmate_guidance:
#     see the bash twin's header, which owns the prose for each field.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE CARRIES ITS OWN JSON WRITER
#
# The bash twin is ~900 lines of jq, and jq's OUTPUT is the contract other
# tooling reads. ConvertTo-Json cannot reproduce it: it orders keys by insertion
# but indents with four spaces, escapes non-ASCII, renders an empty array
# differently under -Compress, and has no way to distinguish an empty object from
# an empty array once a model round-trips. So Write-FmJqJson below is a small
# jq-compatible pretty printer (2-space indent, `[]`/`{}` for empties, jq's exact
# string escape set, `/` left unescaped), and the model it prints is built from
# ordered dictionaries and Lists.
#
# That choice is what makes the differential verification meaningful: the two
# worlds' bytes are compared directly rather than through a canonicalizer that
# would hide a key-order or empty-collection regression.
#
# ---------------------------------------------------------------------------
# WHAT THE PORT DELIBERATELY KEEPS
#
#   THE REGEX DIALECT. Every jq pattern uses POSIX `[[:space:]]`, which in the C
#   locale is exactly six characters. .NET's `\s` additionally matches NBSP and
#   the Unicode space separators, so it is spelled out as `[ \t\n\v\f\r]`
#   throughout - a title containing NBSP must survive identically in both worlds.
#
#   THE GREEDY LEADING `.*`. `metadata` and friends anchor with a greedy `.*`
#   precisely so the LAST occurrence of a key wins. .NET backtracks the same way,
#   so the patterns are transcribed rather than "simplified" to a lastIndexOf.
#
#   THE TRUNCATION ARITHMETIC. The bounded registry and parent-activity reads
#   count BYTES, then drop a partial line, then count lines with an `awk END{NR}`
#   over `printf '%s\n' "$content"` - which counts one EXTRA line when the content
#   already ends in a newline. That quirk decides `line_limit` disclosure, so it
#   is reproduced rather than corrected.
#
# ---------------------------------------------------------------------------
# TWO DECLARED DIVERGENCES
#
#   1. jq. The bash refuses with "fm-fleet-snapshot: jq not found" (exit 1) when
#      jq is absent; this twin has no jq dependency at all and therefore has no
#      such refusal. Every other exit code and message is identical.
#   2. The registry readability gate. The bash reads `stat -c %a` and refuses when
#      no read bit is set. On Windows chmod is inert and every path reads 644/755
#      (docs/powershell-port.md, "the noacl private-file gates"), so this twin
#      decides readability by ATTEMPTING the read - which accepts exactly what the
#      bash accepts on this platform, and refuses only a file that genuinely
#      cannot be opened. Enforcing real ACLs here would make the PowerShell path
#      refuse artifacts the bash path accepts.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force
# validate_secondmate_home: the shared seeded-home boundary checks.
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force

# No param() block - see bin/fm-operational-input.ps1's header for why.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {

    # =========================================================================
    # jq-compatible JSON model and writer
    # =========================================================================

    # An ordered JSON object. Insertion order IS the printed key order, exactly
    # as a jq object literal's is.
    function Get-JObject { return [ordered]@{} }

    # A JSON array that survives PowerShell's collection unrolling. The unary
    # comma is NOT decoration: a bare `return <empty List>` is unrolled to zero
    # objects on the way out of a function, so the caller receives $null and the
    # very next `.Add(...)` fails with "You cannot call a method on a null-valued
    # expression". Every producer of a collection in this file returns it the
    # same way.
    function Get-JArray { return , [System.Collections.Generic.List[object]]::new() }

    # Field read that tolerates an absent key on a dictionary from ANY source -
    # a model built here, or a hashtable parsed from a child process's JSON.
    # StrictMode makes `$obj.missing` a terminating error on some shapes, so
    # nothing in this file reaches into a dictionary any other way.
    function Get-JField {
        param($Obj, [string]$Key)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [System.Collections.IDictionary]) {
            # Unary comma again: a stored value that is itself a COLLECTION would
            # be unrolled on the way out, so an empty array field would come back
            # as $null and the caller's next .Add() would fail. The comma is
            # transparent for scalars.
            if ($Obj.Contains($Key)) { return , $Obj[$Key] }
            return $null
        }
        return $null
    }

    # Nested read: Get-JPath $t 'endpoint' 'target'.
    function Get-JPath {
        param($Obj, [string[]]$Keys)
        $cur = $Obj
        foreach ($k in $Keys) {
            $cur = Get-JField $cur $k
            if ($null -eq $cur) { return $null }
        }
        return , $cur
    }

    # `[]` for a null-or-empty list, so a caller can always `foreach` it.
    function Get-JList {
        param($Value)
        if ($null -eq $Value) { return , (Get-JArray) }
        if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return , $Value }
        $l = Get-JArray
        [void]$l.Add($Value)
        return , $l
    }

    # jq's `sort_by` is STABLE and compares strings by CODEPOINT. Sort-Object is
    # neither by default: it is culture-aware (so "a" and "A" can order by locale
    # rules the oracle never applies) and unstable without -Stable. Both would show
    # up only as an occasional reordered record, which is exactly the kind of
    # difference a differential run must not be allowed to explain away - so
    # ordering is done here, explicitly, with an ordinal comparison and an index
    # tiebreak that makes it stable by construction.
    #
    # A multi-key sort joins its keys with NUL, which is ordinally equivalent to
    # comparing the keys in sequence as long as no key contains NUL - and none of
    # these (dates, ids) can.
    function Get-JSorted {
        param($Source, [scriptblock]$Key)
        $decorated = [System.Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($e in $Source) {
            $decorated.Add([pscustomobject]@{ K = [string](& $Key $e); I = $index; V = $e })
            $index++
        }
        $decorated.Sort([System.Comparison[object]] {
                param($a, $b)
                $c = [string]::CompareOrdinal($a.K, $b.K)
                if ($c -ne 0) { return $c }
                return $a.I.CompareTo($b.I)
            })
        $out = Get-JArray
        foreach ($d in $decorated) { [void]$out.Add($d.V) }
        return , $out
    }

    # jq's string escape set: the five short escapes, \u00xx for the remaining
    # C0 controls and DEL, and NOTHING else - `/` in particular is left alone,
    # and non-ASCII is emitted raw as UTF-8.
    function ConvertTo-JqString {
        param([string]$Text)
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        foreach ($ch in $Text.ToCharArray()) {
            $code = [int]$ch
            switch ($ch) {
                '"' { [void]$sb.Append('\"'); continue }
                '\' { [void]$sb.Append('\\'); continue }
                default {
                    if ($code -eq 8) { [void]$sb.Append('\b') }
                    elseif ($code -eq 12) { [void]$sb.Append('\f') }
                    elseif ($code -eq 10) { [void]$sb.Append('\n') }
                    elseif ($code -eq 13) { [void]$sb.Append('\r') }
                    elseif ($code -eq 9) { [void]$sb.Append('\t') }
                    elseif ($code -lt 32 -or $code -eq 127) {
                        [void]$sb.Append(('\u{0:x4}' -f $code))
                    } else {
                        [void]$sb.Append($ch)
                    }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }

    function ConvertTo-JqJson {
        param($Value, [int]$Indent = 0)
        $pad = ' ' * $Indent
        $inner = ' ' * ($Indent + 2)
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
        if ($Value -is [string]) { return (ConvertTo-JqString $Value) }
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
            return ([string]$Value)
        }
        if ($Value -is [System.Collections.IDictionary]) {
            if ($Value.Count -eq 0) { return '{}' }
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($k in $Value.Keys) {
                $parts.Add($inner + (ConvertTo-JqString ([string]$k)) + ': ' +
                    (ConvertTo-JqJson $Value[$k] ($Indent + 2)))
            }
            return "{`n" + [string]::Join(",`n", $parts) + "`n$pad}"
        }
        if ($Value -is [System.Collections.IList]) {
            if ($Value.Count -eq 0) { return '[]' }
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($e in $Value) {
                $parts.Add($inner + (ConvertTo-JqJson $e ($Indent + 2)))
            }
            return "[`n" + [string]::Join(",`n", $parts) + "`n$pad]"
        }
        return (ConvertTo-JqString ([string]$Value))
    }

    # =========================================================================
    # context and bounds
    # =========================================================================

    $context = Get-FmContext $PSScriptRoot
    $fmRoot = $context.Root
    $fmHome = $context.Home
    $stateDir = $context.State
    $dataDir = $context.Data
    $configDir = $context.Config
    $projectsDir = $context.Projects
    $backlogPath = Join-Path $dataDir 'backlog.md'

    $snapshotNow = Get-FmEnv 'FM_SNAPSHOT_NOW'
    if ($snapshotNow -eq '') {
        $snapshotNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $snapshotEpochRaw = Get-FmEnv 'FM_SNAPSHOT_NOW_EPOCH'
    if ($snapshotEpochRaw -eq '') {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($snapshotNow, 'yyyy-MM-ddTHH:mm:ssZ',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            $snapshotEpochRaw = [string]([DateTimeOffset]::new($parsed, [TimeSpan]::Zero).ToUnixTimeSeconds())
        } else {
            $snapshotEpochRaw = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
    }
    # `case ... in ''|*[!0-9]*)` - a bare non-negative decimal, or fall back to now.
    if ($snapshotEpochRaw -notmatch '^[0-9]+$') {
        $snapshotEpochRaw = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $snapshotEpoch = [long]$snapshotEpochRaw

    # Cross-home bounds are explicit so one broken or unexpectedly large home
    # cannot hang or explode the parent snapshot.
    $boundSecondmates = Get-FmEnv 'FM_SNAPSHOT_SECONDMATES' '20'
    if ($boundSecondmates -notmatch '^[0-9]+$') {
        Write-FmErr 'fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer'
        Exit-FmScript 2
    }
    $bounds = [ordered]@{}
    foreach ($pair in @(
            @('FM_SNAPSHOT_SECONDMATE_TIMEOUT', '8'),
            @('FM_SNAPSHOT_SECONDMATE_MAX_BYTES', '262144'),
            @('FM_SNAPSHOT_SECONDMATE_CHILDREN', '20'),
            @('FM_SNAPSHOT_SECONDMATE_QUEUED', '20'),
            @('FM_SNAPSHOT_SECONDMATE_DECISIONS', '20'),
            @('FM_SNAPSHOT_TERMINAL_LINES', '8'),
            @('FM_SNAPSHOT_TERMINAL_BYTES', '4096'),
            @('FM_SNAPSHOT_TERMINAL_TIMEOUT', '2'),
            @('FM_SNAPSHOT_PARENT_ACTIVITY_LINES', '256'),
            @('FM_SNAPSHOT_PARENT_ACTIVITY_BYTES', '65536'),
            @('FM_SNAPSHOT_PARENT_ACTIVITIES', '20'),
            @('FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT', '2'),
            @('FM_SNAPSHOT_REGISTRY_LINES', '256'),
            @('FM_SNAPSHOT_REGISTRY_BYTES', '65536'),
            @('FM_SNAPSHOT_REGISTRY_RECORDS', '40'),
            @('FM_SNAPSHOT_REGISTRY_TIMEOUT', '2'))) {
        $value = Get-FmEnv $pair[0] $pair[1]
        # validate_positive_bound: '' and 0 and any non-digit are all refusals.
        if ($value -notmatch '^[0-9]+$' -or [long]$value -eq 0) {
            Write-FmErr ('fm-fleet-snapshot: ' + $pair[0] + ' must be a positive integer')
            Exit-FmScript 2
        }
        $bounds[$pair[0]] = [long]$value
    }
    $landedPerHomeRaw = Get-FmEnv 'FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME' '10'
    if ($landedPerHomeRaw -notmatch '^[0-9]+$') { $landedPerHomeRaw = '10' }
    $landedPerHome = [long]$landedPerHomeRaw

    # The here-doc, verbatim. Kept as a STRING rather than a writer so the same
    # bytes can go to stdout (--help) or stderr (bad usage) without a redirection
    # dance, and CRLF-normalized because a here-string picks up the source file's
    # line endings and this text is compared byte-for-byte.
    $usageText = (@'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, and marks inventory contradictions or unavailable child state invalid.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, and plural blocker fields for downstream
projections. A captain hold is actionable only when every blocker is Done.
Cross-home reads use FM_SNAPSHOT_SECONDMATES (default 20, 0 lifts the count
bound), FM_SNAPSHOT_SECONDMATE_TIMEOUT, and FM_SNAPSHOT_SECONDMATE_MAX_BYTES.
Terminal contradiction evidence uses
FM_SNAPSHOT_TERMINAL_LINES, FM_SNAPSHOT_TERMINAL_BYTES, and
FM_SNAPSHOT_TERMINAL_TIMEOUT and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES,
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, FM_SNAPSHOT_PARENT_ACTIVITIES, and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT, with truncation disclosed in the result.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES,
FM_SNAPSHOT_REGISTRY_BYTES, FM_SNAPSHOT_REGISTRY_RECORDS, and
FM_SNAPSHOT_REGISTRY_TIMEOUT, with unavailability and truncation disclosed.

'@) -replace "`r`n", "`n"

    $outputMode = 'json'
    # `${1:---json}` uses `:-`, so an EMPTY first argument is the default too.
    $firstArg = '--json'
    if ($fmArgv.Count -ge 1 -and -not [string]::IsNullOrEmpty([string]$fmArgv[0])) {
        $firstArg = [string]$fmArgv[0]
    }
    if ($firstArg -ceq '--json') {
        $outputMode = 'json'
    } elseif ($firstArg -ceq '--secondmate-home-summary') {
        $outputMode = 'secondmate-home-summary'
    } elseif ($firstArg -ceq '-h' -or $firstArg -ceq '--help') {
        Write-FmRaw $usageText
        Exit-FmScript 0
    } else {
        # `usage >&2` - the same text, on the error stream.
        [Console]::Error.Write($usageText)
        Exit-FmScript 2
    }

    # =========================================================================
    # the POSIX space class, spelled out (see the header)
    # =========================================================================

    $SP = '[ \t\n\v\f\r]'
    $NSP = ' \t\n\v\f\r'

    function Get-Trimmed {
        param([AllowEmptyString()][AllowNull()][string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        return ($Text -replace "^[$NSP]+|[$NSP]+$", '')
    }

    # jq's `.[:n]` counts CODEPOINTS; .NET counts UTF-16 units. They agree for
    # everything below U+10000, which is the whole of this repo's record
    # vocabulary; a supplementary-plane character in a title is the one place the
    # two could cut differently, and it is called out rather than papered over.
    function Get-Truncated {
        param($Value, [int]$Limit)
        $s = if ($null -eq $Value) { 'null' } else { [string]$Value }
        $s = $s -replace '[ \t\n\r\f\v]+', ' '
        if ($s.Length -gt $Limit) { return $s.Substring(0, $Limit) + [char]0x2026 }
        return $s
    }

    # `capture($re) | .v` with jq's null-on-no-match, then `trim`.
    function Get-Captured {
        param([string]$Text, [string]$Pattern)
        $m = [regex]::Match($Text, $Pattern)
        if (-not $m.Success) { return $null }
        $g = $m.Groups['v']
        if (-not $g.Success) { return $null }
        return (Get-Trimmed $g.Value)
    }

    function Get-MetadataValue {
        param([string]$Text, [string]$Key)
        return (Get-Captured $Text (".*(?:\(|,$SP*)" + [regex]::Escape($Key) + ":$SP*(?<v>[^,)]*)"))
    }

    function Get-MetadataWord {
        param([string]$Text, [string]$Key)
        return (Get-Captured $Text (".*(?:\(|,$SP*)" + [regex]::Escape($Key) + "$SP+(?<v>[^,)]*)"))
    }

    $urlPattern = "https?://[^$NSP)`"<>]+"
    $wrappedUrlPattern = "<?$urlPattern>?"

    function Get-WithoutTrailingMetadataGroup {
        param([string]$Text)
        $re = "$SP*\($SP*(?:(?:repo|kind|priority|hold|hold-kind):$SP*[^)]*|" +
        "(?:since|merged|reported|done)$SP+[^)]*)$SP*\)$SP*$"
        $out = $Text
        # `reduce range(0;20)`: a bounded repeat, not a loop-until-stable, so a
        # 21st trailing group survives in both worlds.
        #
        # The INSTANCE Replace overload is what takes a count. The static
        # [regex]::Replace(input, pattern, replacement, N) does NOT: its fourth
        # parameter is RegexOptions, so a literal 1 there silently means
        # IgnoreCase and replaces EVERY match. Every jq `sub` below therefore goes
        # through a constructed Regex.
        $rx = [regex]::new($re)
        for ($i = 0; $i -lt 20; $i++) { $out = $rx.Replace($out, '', 1) }
        return $out
    }

    function Get-WithoutTitleArtifact {
        param([string]$Text)
        $out = $Text
        foreach ($p in @(
                "$SP+-$SP+data/[^$NSP)]+/report\.md$",
                "$SP+data/[^$NSP)]+/report\.md$",
                "$SP+-$SP+local main$",
                "$SP+local main$",
                "$SP+-$SP*$")) {
            $out = [regex]::new($p).Replace($out, '', 1)
        }
        return $out
    }

    function Get-CleanTitle {
        param([string]$Text)
        $out = Get-WithoutTrailingMetadataGroup $Text
        $out = Get-WithoutTitleArtifact $out
        $out = $out -replace "$SP+", ' '
        return (Get-Trimmed $out)
    }

    # =========================================================================
    # small file / process helpers
    # =========================================================================

    function Test-PathPresent {
        param([AllowEmptyString()][AllowNull()][string]$Path)
        if ([string]::IsNullOrEmpty($Path)) { return $false }
        try { return (Test-Path -LiteralPath (ConvertTo-FmNativePath $Path)) } catch { return $false }
    }

    function Get-PathPresentJson {
        param([AllowEmptyString()][AllowNull()][string]$Path)
        $o = Get-JObject
        $o['path'] = $Path
        $o['present'] = (Test-PathPresent $Path)
        return $o
    }

    function Get-NullPathJson {
        $o = Get-JObject
        $o['path'] = $null
        $o['present'] = $false
        return $o
    }

    # `grep -v '^[[:space:]]*$' "$1" | tail -1`, or '' when the file is absent.
    function Get-LastNonEmptyLine {
        param([string]$Path)
        $last = ''
        foreach ($line in (Get-FmFileLines $Path)) {
            if ($line -match "^$SP*$") { continue }
            $last = $line
        }
        return $last
    }

    function Get-FirstPrUrlInFile {
        param([string]$Path)
        foreach ($line in (Get-FmFileLines $Path)) {
            $m = [regex]::Match($line, "https?://[^$NSP)`"]+/pull/[0-9]+")
            if ($m.Success) { return $m.Value }
        }
        return ''
    }

    function Get-FileMtimeEpoch {
        param([AllowEmptyString()][AllowNull()][string]$Path)
        if ([string]::IsNullOrEmpty($Path)) { return $null }
        try {
            $native = ConvertTo-FmNativePath $Path
            if (-not [System.IO.File]::Exists($native)) { return $null }
            return ([DateTimeOffset]::new([System.IO.File]::GetLastWriteTimeUtc($native),
                    [TimeSpan]::Zero).ToUnixTimeSeconds())
        } catch { return $null }
    }

    # `env A=1 B=2 <child>`: the values are applied to THIS process, the child
    # inherits them, and the previous values are restored on every path - which is
    # what keeps a per-secondmate read from leaking into the next one.
    function Invoke-ChildWithEnv {
        param(
            [string]$Name,
            [string[]]$Arguments,
            [System.Collections.IDictionary]$Environment,
            [int]$TimeoutSeconds = 0
        )
        $saved = @{}
        foreach ($k in $Environment.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable([string]$k)
        }
        try {
            foreach ($k in $Environment.Keys) {
                [Environment]::SetEnvironmentVariable([string]$k, [string]$Environment[$k])
            }
            $call = @{ Name = $Name; Arguments = $Arguments; BinDir = $PSScriptRoot }
            if ($TimeoutSeconds -gt 0) { $call['TimeoutSeconds'] = $TimeoutSeconds }
            return (Invoke-FmScript @call)
        } finally {
            foreach ($k in $saved.Keys) {
                [Environment]::SetEnvironmentVariable([string]$k, $saved[$k])
            }
        }
    }

    # =========================================================================
    # backlog
    # =========================================================================

    $rowMatchBracket = "^[-*]$SP+\[(?<check>[ xX])\]$SP+(?<id>[^$NSP]+)$SP+-$SP+(?<rest>.*)$"
    $rowMatchBold = "^[-*]$SP+\*\*(?<id>[^*]+)\*\*$SP+-$SP+(?<rest>.*)$"

    function Test-StructuredRow {
        param([string]$Line)
        if ($Line -match "^[-*]$SP+\[[ xX]\]$SP+[^$NSP]+$SP+-$SP+") { return $true }
        if ($Line -match "^[-*]$SP+\*\*[^*]+\*\*$SP+-$SP+") { return $true }
        return $false
    }

    function Get-BlockedByIdList {
        param([string]$Text)
        $ids = Get-JArray
        foreach ($m in [regex]::Matches($Text, "blocked-by:$SP+(?<id>[^$NSP)]+)")) {
            $v = $m.Groups['id'].Value
            if (-not $ids.Contains($v)) { [void]$ids.Add($v) }
        }
        return , $ids
    }

    function Get-BacklogRowJson {
        param([string]$Line, [string]$Section, [long]$Order)

        $m = [regex]::Match($Line, $rowMatchBracket)
        $check = ' '
        if ($m.Success) {
            $check = $m.Groups['check'].Value
        } else {
            $m = [regex]::Match($Line, $rowMatchBold)
        }
        if (-not $m.Success) {
            $r = Get-JObject
            $r['order'] = $Order
            $r['state'] = $Section
            $r['structured'] = $false
            $r['id'] = $null
            $r['raw'] = $Line
            $r['body_lines'] = Get-JArray
            $r['body_excerpt'] = $null
            return $r
        }

        $rest = $m.Groups['rest'].Value

        # title_of: strip wrapped URLs, then the blocked-by clause in both its
        # "with a reason" and bare forms, then clean.
        $title = [regex]::Replace($rest, $wrappedUrlPattern, '')
        $title = [regex]::new("$SP*blocked-by:$SP+[^$NSP)]+$SP+-$SP+.*$").Replace($title, '', 1)
        $title = [regex]::Replace($title, "$SP*blocked-by:$SP+[^$NSP]+", '')
        $title = Get-CleanTitle $title

        $links = Get-JArray
        foreach ($lm in [regex]::Matches($rest, $urlPattern)) { [void]$links.Add($lm.Value) }
        $prUrl = $null
        foreach ($l in $links) { if ($l -match '/pull/[0-9]+') { $prUrl = $l; break } }

        $blockedReason = Get-Captured $rest ".*blocked-by:$SP*[^$NSP)]+$SP+-$SP*(?<v>.*)$"
        if ($null -ne $blockedReason) {
            $blockedReason = Get-CleanTitle $blockedReason
            if ($blockedReason -eq '') { $blockedReason = $null }
        }

        $merged = Get-MetadataWord $rest 'merged'
        $reported = Get-MetadataWord $rest 'reported'
        $doneWord = Get-MetadataWord $rest 'done'
        $completion = Get-JObject
        if ($null -ne $merged) { $completion['verb'] = 'merged'; $completion['date'] = $merged }
        elseif ($null -ne $reported) { $completion['verb'] = 'reported'; $completion['date'] = $reported }
        elseif ($null -ne $doneWord) { $completion['verb'] = 'done'; $completion['date'] = $doneWord }
        else { $completion['verb'] = $null; $completion['date'] = $null }

        $r = Get-JObject
        $r['order'] = $Order
        $r['state'] = $Section
        $r['structured'] = $true
        $r['id'] = Get-Trimmed $m.Groups['id'].Value
        $r['checked'] = [bool]($check -match '[xX]')
        $r['title'] = $title
        $r['repo'] = Get-MetadataValue $rest 'repo'
        $r['kind'] = Get-MetadataValue $rest 'kind'
        $r['priority'] = Get-MetadataValue $rest 'priority'
        $r['hold_reason'] = Get-MetadataValue $rest 'hold'
        $r['hold_kind'] = Get-MetadataValue $rest 'hold-kind'
        $r['blocked_by'] = Get-Captured $rest ".*blocked-by:$SP*(?<v>[^$NSP)]+).*"
        $r['blocked_by_ids'] = Get-BlockedByIdList $rest
        $r['blocked_reason'] = $blockedReason
        $r['since'] = Get-MetadataWord $rest 'since'
        $r['merged'] = $merged
        $r['reported'] = $reported
        $r['done'] = $doneWord
        $r['completion'] = $completion
        $r['links'] = $links
        $r['pr_url'] = $prUrl
        $r['report_path'] = Get-Captured $rest ".*(?<v>data/[^$NSP)]+/report\.md).*"
        $r['local_note'] = Get-Captured (Get-WithoutTrailingMetadataGroup $rest) ".*(?:^|$SP+-$SP+|$SP)(?<v>local main)$"
        $r['raw'] = $Line
        $r['body_lines'] = Get-JArray
        $r['body_excerpt'] = $null
        return $r
    }

    function Get-BacklogJson {
        param([string]$Path)

        $result = Get-JObject
        $result['path'] = $Path
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) {
            $result['present'] = $false
            $result['records'] = Get-JArray
            return $result
        }
        $result['present'] = $true
        $records = Get-JArray
        $result['records'] = $records

        $section = $null
        $order = 0L
        foreach ($line in (Get-FmFileLines $Path)) {
            if ($line -match "^##$SP+") {
                $heading = Get-Trimmed ([regex]::new("^##$SP+").Replace($line, '', 1))
                $section = switch -CaseSensitive ($heading) {
                    'In flight' { 'in_flight' }
                    'Queued' { 'queued' }
                    'Done' { 'done' }
                    default { $null }
                }
                continue
            }
            if ($null -eq $section -or (Get-Trimmed $line) -eq '') { continue }
            if (Test-StructuredRow $line) {
                $order++
                [void]$records.Add((Get-BacklogRowJson -Line $line -Section $section -Order $order))
                continue
            }
            if ($records.Count -gt 0 -and (Get-JField $records[$records.Count - 1] 'structured') -eq $true -and
                $line -match "^$SP+") {
                $body = Get-Trimmed $line
                if ($body -ne '') { [void](Get-JField $records[$records.Count - 1] 'body_lines').Add($body) }
                continue
            }
            $order++
            $r = Get-JObject
            $r['order'] = $order
            $r['state'] = $section
            $r['structured'] = $false
            $r['id'] = $null
            $r['raw'] = $line
            $r['body_lines'] = Get-JArray
            $r['body_excerpt'] = $null
            [void]$records.Add($r)
        }

        foreach ($r in $records) {
            $bodyLines = Get-JField $r 'body_lines'
            if ($bodyLines.Count -gt 0) {
                $joined = [string]::Join(' ', $bodyLines)
                if ($joined.Length -gt 240) { $joined = $joined.Substring(0, 240) }
                $r['body_excerpt'] = $joined
            }
        }

        # `$resolved_ids`: an id resolves only when EVERY structured record
        # carrying it is Done, so a repeated id with one open row stays open.
        $resolved = @{}
        foreach ($r in $records) {
            if ((Get-JField $r 'structured') -ne $true) { continue }
            $id = [string](Get-JField $r 'id')
            $prev = if ($resolved.ContainsKey($id)) { [bool]$resolved[$id] } else { $true }
            $resolved[$id] = ($prev -and ((Get-JField $r 'state') -ceq 'done'))
        }

        foreach ($r in $records) {
            if ((Get-JField $r 'structured') -ne $true) { continue }
            $unresolved = Get-JArray
            foreach ($b in (Get-JField $r 'blocked_by_ids')) {
                if (-not ($resolved.ContainsKey($b) -and $resolved[$b] -eq $true)) { [void]$unresolved.Add($b) }
            }
            $r['unresolved_blocker_ids'] = $unresolved
            $state = [string](Get-JField $r 'state')
            $holdReason = Get-JField $r 'hold_reason'
            $holdKind = Get-JField $r 'hold_kind'
            $kind = Get-JField $r 'kind'
            $role = if ($state -ceq 'in_flight' -and $null -ne $holdReason -and $null -ne $holdKind) { 'held' }
            elseif ($state -ceq 'in_flight' -and $kind -ceq 'program') { 'program' }
            elseif ($state -ceq 'in_flight') { 'worker' }
            elseif ($state -ceq 'queued') { 'queued' }
            else { 'done' }
            $r['current_role'] = $role
            $r['requires_child_metadata'] = ($role -ceq 'worker')
            $r['captain_actionable'] = ($state -ceq 'queued' -and $kind -ceq 'captain' -and
                $holdKind -ceq 'captain' -and $null -ne $holdReason -and $unresolved.Count -eq 0)
        }
        return $result
    }

    # =========================================================================
    # tasks
    # =========================================================================

    # `state: X · source: Y · detail` - the separator is a middle dot with a
    # space either side, and BOTH splits use the FIRST occurrence (the bash's
    # `%%`-longest-suffix and `#`-shortest-prefix removals agree on that).
    function Get-CrewStateJson {
        param([string]$Id)
        # Named crewEnv, not env: `$env` is PowerShell's environment PROVIDER
        # drive, and shadowing it inside a script that then sets real environment
        # variables is action at a distance.
        $crewEnv = [ordered]@{
            FM_ROOT_OVERRIDE     = $fmRoot
            FM_HOME              = $fmHome
            FM_STATE_OVERRIDE    = $stateDir
            FM_DATA_OVERRIDE     = $dataDir
            FM_PROJECTS_OVERRIDE = $projectsDir
            FM_CONFIG_OVERRIDE   = $configDir
        }
        $r = Invoke-ChildWithEnv -Name 'fm-crew-state' -Arguments @($Id) -Environment $crewEnv
        $raw = ''
        if ($r.Ok) { $raw = $r.StdOut }
        # `$( ... | head -1 )`: the first line, trailing newlines stripped.
        $raw = @(($raw -replace "`r", '') -split "`n")[0]

        $sep = ' ' + [char]0x00B7 + ' '
        $state = 'unknown'
        $source = 'none'
        $detail = ''
        $marker = $sep + 'source: '
        if ($raw.StartsWith('state: ', [System.StringComparison]::Ordinal)) {
            $rest0 = $raw.Substring('state: '.Length)
            $idx = $rest0.IndexOf($marker, [System.StringComparison]::Ordinal)
            if ($idx -ge 0) {
                $state = $rest0.Substring(0, $idx)
                $rest = $rest0.Substring($idx + $marker.Length)
                $sepIdx = $rest.IndexOf($sep, [System.StringComparison]::Ordinal)
                if ($sepIdx -ge 0) {
                    $source = $rest.Substring(0, $sepIdx)
                    $detail = $rest.Substring($sepIdx + $sep.Length)
                } else {
                    $source = $rest
                }
            }
        }
        $o = Get-JObject
        $o['state'] = $state
        $o['source'] = $source
        $o['detail'] = $detail
        $o['raw'] = $raw
        return $o
    }

    function Get-StatusEventJson {
        param([string]$Log)
        $present = $false
        $raw = ''
        $verb = ''
        $note = ''
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $Log))) {
            $present = $true
            $raw = Get-LastNonEmptyLine $Log
            $verb = Get-FmStatusLineVerb $raw
            $note = Get-FmStatusLineNote $raw
        }
        $lastEvent = Get-JObject
        $lastEvent['state'] = $verb
        $lastEvent['note'] = $note
        $lastEvent['raw'] = $raw
        $o = Get-JObject
        $o['path'] = $Log
        $o['present'] = $present
        $o['kind'] = 'event_history'
        $o['last_event'] = $lastEvent
        return $o
    }

    # `key<TAB>verb<TAB>summary` lines; anything without two tabs is dropped,
    # which is what jq's `capture(...)? | select(. != null)` does.
    function ConvertFrom-KeyedTsv {
        param([AllowEmptyString()][AllowNull()][string]$Text)
        $out = Get-JArray
        if ([string]::IsNullOrEmpty($Text)) { return , $out }
        foreach ($line in ($Text -split "`n")) {
            if ($line -eq '') { continue }
            $m = [regex]::Match($line, "^(?<key>[^`t]*)`t(?<verb>[^`t]*)`t(?<summary>.*)$")
            if (-not $m.Success) { continue }
            $o = Get-JObject
            $o['key'] = $m.Groups['key'].Value
            $o['verb'] = $m.Groups['verb'].Value
            $o['summary'] = $m.Groups['summary'].Value
            [void]$out.Add($o)
        }
        return , $out
    }

    function Get-TaskListJson {
        $tasks = Get-JArray
        $stateNative = ConvertTo-FmNativePath $stateDir
        if (-not (Test-Path -LiteralPath $stateNative -PathType Container)) { return , $tasks }

        $metas = [System.Collections.Generic.List[string]]::new()
        foreach ($f in [System.IO.Directory]::EnumerateFiles($stateNative, '*.meta')) { $metas.Add($f) }
        $metas.Sort([System.StringComparer]::Ordinal)

        foreach ($metaFile in $metas) {
            $id = [System.IO.Path]::GetFileNameWithoutExtension($metaFile)
            # Recomposed from $stateDir rather than used as enumerated, so the
            # recorded meta path is spelled exactly like the sibling status and
            # report paths this snapshot also publishes.
            $meta = Join-Path $stateDir "$id.meta"
            $kind = Get-FmMetaValue $meta 'kind'
            if ($kind -eq '') { $kind = 'ship' }
            $harness = Get-FmMetaValue $meta 'harness'
            $mode = Get-FmMetaValue $meta 'mode'
            $yolo = Get-FmMetaValue $meta 'yolo'
            $project = Get-FmMetaValue $meta 'project'
            $worktree = Get-FmMetaValue $meta 'worktree'
            $homeValue = Get-FmMetaValue $meta 'home'
            $projects = Get-FmMetaValue $meta 'projects'
            $backend = Get-FmBackendOfMeta $meta
            $target = Get-FmBackendTargetOfMeta $meta
            $statusLog = Join-Path $stateDir "$id.status"
            $reportPath = Join-Path (Join-Path $dataDir $id) 'report.md'

            $pr = Get-FmMetaValue $meta 'pr'
            $prSource = 'meta'
            if ($pr -eq '') {
                $pr = Get-FirstPrUrlInFile $statusLog
                $prSource = 'status_event'
            }
            if ($pr -eq '') { $prSource = 'absent' }

            $currentJson = Get-CrewStateJson $id
            $eventJson = Get-StatusEventJson $statusLog
            $lastEventRaw = [string](Get-JPath $eventJson @('last_event', 'raw'))
            $currentState = [string](Get-JField $currentJson 'state')
            $currentSource = [string](Get-JField $currentJson 'source')

            # Durable keyed open-decision set: fold the WHOLE status stream so a
            # later unrelated event can never mask a still-open captain decision.
            # The set is then reconciled against the crew LIFECYCLE, which only
            # clears a decision the crew has provably moved past. Secondmates are
            # excluded from lifecycle clearing: they are persistent and multiplex
            # many concerns onto one stream, so activity on one concern must never
            # clear another concern's keyed decision.
            $openDecisionsTsv = Get-FmStatusOpenDecisions $statusLog
            $liveWorking = (($currentSource -ceq 'run-step' -or $currentSource -ceq 'pane') -and
                $currentState -cne 'parked' -and $currentState -cne 'blocked')
            $terminal = ($currentState -ceq 'done' -or $currentState -ceq 'failed')
            if ($kind -cne 'secondmate' -and ($liveWorking -or $terminal)) { $openDecisionsTsv = '' }
            $openDecisions = ConvertFrom-KeyedTsv $openDecisionsTsv
            $pendingDecision = $false
            $blockedEvent = $false
            foreach ($d in $openDecisions) {
                if ((Get-JField $d 'verb') -ceq 'needs-decision') { $pendingDecision = $true }
                if ((Get-JField $d 'verb') -ceq 'blocked') { $blockedEvent = $true }
            }

            $endpointExists = $null
            if ($target -ne '') {
                $endpointExists = [bool](Test-FmBackendTargetExists $backend $target "fm-$id")
            }
            $agentAlive = 'not_checked'
            if ($kind -ceq 'secondmate' -and $target -ne '') {
                $alive = Get-FmBackendAgentAlive $backend $target
                $agentAlive = if ([string]::IsNullOrEmpty($alive)) { 'unknown' } else { $alive }
            }

            $paths = Get-JObject
            $paths['meta'] = Get-PathPresentJson $meta
            $paths['status_log'] = $eventJson
            $paths['worktree'] = if ($worktree -ne '') { Get-PathPresentJson $worktree } else { Get-NullPathJson }
            $paths['home'] = if ($homeValue -ne '') { Get-PathPresentJson $homeValue } else { Get-NullPathJson }
            $paths['report'] = Get-PathPresentJson $reportPath

            $secondmateProjects = Get-JArray
            if ($projects -ne '') {
                foreach ($p in ($projects -split ',')) {
                    $t = Get-Trimmed $p
                    if ($t -ne '') { [void]$secondmateProjects.Add($t) }
                }
            }

            $currentOut = Get-JObject
            foreach ($k in $currentJson.Keys) { $currentOut[$k] = $currentJson[$k] }
            $currentOut['observed_at'] = $snapshotNow
            $currentOut['freshness'] = 'fresh'

            $endpoint = Get-JObject
            $endpoint['target'] = if ($target -eq '') { $null } else { $target }
            $endpoint['exists'] = $endpointExists
            $endpoint['agent_alive'] = $agentAlive
            $endpoint['status'] = if ($endpointExists -eq $false) { 'absent' }
            elseif ($agentAlive -ceq 'alive' -or $agentAlive -ceq 'dead') { $agentAlive }
            else { 'unknown' }
            $endpoint['observed_at'] = $snapshotNow
            $endpoint['freshness'] = 'fresh'

            $prObj = Get-JObject
            $prObj['url'] = if ($pr -eq '') { $null } else { $pr }
            $prObj['source'] = $prSource

            $hints = Get-JObject
            $hints['pending_decision'] = $pendingDecision
            $hints['blocked_event'] = $blockedEvent
            $hints['open_decisions'] = $openDecisions
            $hints['scout_report_present'] = (Test-PathPresent $reportPath)
            $hints['last_event_text'] = $lastEventRaw

            $actions = Get-JObject
            if ($kind -ceq 'secondmate') {
                $actions['send'] = "bin/fm-send.sh fm-$id '<request>'"
                $actions['watch'] = 'read status/doc return channel; do not routinely fm-peek a secondmate for answers'
                $actions['return_channel_note'] = 'Secondmate answers come back through status/doc paths after a marked fm-send request.'
            } else {
                $actions['watch'] = "bin/fm-peek.sh fm-$id"
                $actions['steer'] = "bin/fm-send.sh fm-$id '<instruction>'"
                $actions['return_channel_note'] = $null
            }

            $t = Get-JObject
            $t['id'] = $id
            $t['kind'] = $kind
            $t['harness'] = $harness
            $t['mode'] = $mode
            $t['yolo'] = $yolo
            $t['project'] = $project
            $t['backend'] = $backend
            $t['paths'] = $paths
            $t['secondmate_projects'] = $secondmateProjects
            $t['current_state'] = $currentOut
            $t['endpoint'] = $endpoint
            $t['pr'] = $prObj
            $t['hints'] = $hints
            $t['actions'] = $actions
            [void]$tasks.Add($t)
        }

        # `jq -s 'sort_by(.id)'` - codepoint order, which is Ordinal.
        return , (Get-JSorted $tasks { param($t) [string](Get-JField $t 'id') })
    }

    # =========================================================================
    # main-home inventory
    # =========================================================================

    function Get-MainInventoryJson {
        param($Backlog, $Tasks)
        $records = Get-JList (Get-JField $Backlog 'records')
        $taskIds = @{}
        foreach ($t in $Tasks) { $taskIds[[string](Get-JField $t 'id')] = $true }

        $unstructuredCurrent = 0
        $orphan = Get-JArray
        foreach ($r in $records) {
            $state = Get-JField $r 'state'
            $structured = (Get-JField $r 'structured') -eq $true
            if (($state -ceq 'in_flight' -or $state -ceq 'queued') -and -not $structured) {
                $unstructuredCurrent++
            }
            if ($state -ceq 'in_flight' -and $structured -and (Get-JField $r 'requires_child_metadata') -eq $true) {
                $id = [string](Get-JField $r 'id')
                if (-not $taskIds.ContainsKey($id)) { [void]$orphan.Add($id) }
            }
        }
        $o = Get-JObject
        $o['valid'] = ($unstructuredCurrent -eq 0 -and $orphan.Count -eq 0)
        $o['reason'] = if ($unstructuredCurrent -gt 0) { 'unstructured current backlog row' }
        elseif ($orphan.Count -gt 0) { 'in-flight backlog item has no child metadata' }
        else { $null }
        $o['orphan_in_flight'] = $orphan
        $o['unstructured_current_count'] = $unstructuredCurrent
        return $o
    }

    # =========================================================================
    # secondmate home summary
    # =========================================================================

    function Get-SecondmateHomeSummaryJson {
        param($Backlog, $Tasks)

        $records = Get-JList (Get-JField $Backlog 'records')
        $childN = [int]$bounds['FM_SNAPSHOT_SECONDMATE_CHILDREN']
        $queuedN = [int]$bounds['FM_SNAPSHOT_SECONDMATE_QUEUED']
        $decisionsN = [int]$bounds['FM_SNAPSHOT_SECONDMATE_DECISIONS']
        $landedN = [int]$landedPerHome

        function Get-TaskById {
            param($TaskList, [string]$Id)
            foreach ($t in $TaskList) { if ((Get-JField $t 'id') -ceq $Id) { return $t } }
            return $null
        }

        $unstructuredCurrent = 0
        $ownedInFlight = Get-JArray
        foreach ($r in $records) {
            $state = Get-JField $r 'state'
            $structured = (Get-JField $r 'structured') -eq $true
            if (($state -ceq 'in_flight' -or $state -ceq 'queued') -and -not $structured) { $unstructuredCurrent++ }
            if ($state -ceq 'in_flight' -and $structured) { [void]$ownedInFlight.Add($r) }
        }

        $queuedAll = Get-JArray
        foreach ($r in $records) {
            if ((Get-JField $r 'structured') -ne $true) { continue }
            $state = Get-JField $r 'state'
            if ($state -ceq 'queued') { [void]$queuedAll.Add($r); continue }
            if ($state -ceq 'in_flight' -and (Get-JField $r 'current_role') -ceq 'held') {
                $t = Get-TaskById $Tasks ([string](Get-JField $r 'id'))
                $working = ($null -ne $t -and (Get-JPath $t @('current_state', 'state')) -ceq 'working')
                if (-not $working) { [void]$queuedAll.Add($r) }
            }
        }

        $captainHolds = Get-JArray
        foreach ($r in $queuedAll) {
            if ((Get-JField $r 'captain_actionable') -ne $true) { continue }
            $o = Get-JObject
            $o['id'] = Get-JField $r 'id'
            $o['key'] = Get-JField $r 'id'
            $o['verb'] = 'captain-hold'
            $o['summary'] = Get-Truncated (Get-JField $r 'title') 160
            $o['reason'] = Get-Truncated (Get-JField $r 'hold_reason') 160
            $o['source'] = 'backlog'
            [void]$captainHolds.Add($o)
        }

        $landedAll = Get-JArray
        foreach ($r in $records) {
            if ((Get-JField $r 'state') -cne 'done') { continue }
            if ((Get-JField $r 'structured') -ne $true) { continue }
            if ((Get-JField $r 'kind') -ceq 'captain') { continue }
            $o = Get-JObject
            $o['id'] = Get-Truncated (Get-JField $r 'id') 120
            $o['title'] = Get-Truncated (Get-JField $r 'title') 120
            $o['pr_url'] = if ($null -eq (Get-JField $r 'pr_url')) { $null } else { Get-Truncated (Get-JField $r 'pr_url') 500 }
            $o['report_path'] = if ($null -eq (Get-JField $r 'report_path')) { $null } else { Get-Truncated (Get-JField $r 'report_path') 500 }
            $o['local_note'] = if ($null -eq (Get-JField $r 'local_note')) { $null } else { Get-Truncated (Get-JField $r 'local_note') 120 }
            $o['completion'] = Get-JField $r 'completion'
            [void]$landedAll.Add($o)
        }
        # `sort_by([(.completion.date // ""), .id]) | reverse` - a STABLE sort in
        # jq, then reversed, so equal keys come back in reverse input order.
        $landedSorted = Get-JArray
        $ordered = Get-JSorted $landedAll {
            param($e)
            $d = Get-JPath $e @('completion', 'date')
            $d = if ($null -eq $d) { '' } else { [string]$d }
            return ($d + [char]0 + [string](Get-JField $e 'id'))
        }
        for ($i = $ordered.Count - 1; $i -ge 0; $i--) { [void]$landedSorted.Add($ordered[$i]) }

        $unknownChildren = Get-JArray
        foreach ($t in $Tasks) {
            if ((Get-JPath $t @('current_state', 'state')) -ceq 'unknown') { [void]$unknownChildren.Add($t) }
        }
        $ownedIds = @{}
        foreach ($r in $ownedInFlight) { $ownedIds[[string](Get-JField $r 'id')] = $true }
        $taskIds = @{}
        foreach ($t in $Tasks) { $taskIds[[string](Get-JField $t 'id')] = $true }

        $orphanInFlight = Get-JArray
        foreach ($r in $ownedInFlight) {
            if ((Get-JField $r 'requires_child_metadata') -ne $true) { continue }
            if (-not $taskIds.ContainsKey([string](Get-JField $r 'id'))) { [void]$orphanInFlight.Add($r) }
        }
        $unownedChildren = Get-JArray
        foreach ($t in $Tasks) {
            if ($ownedIds.ContainsKey([string](Get-JField $t 'id'))) { continue }
            $o = Get-JObject
            $o['id'] = Get-JField $t 'id'
            $o['state'] = Get-JPath $t @('current_state', 'state')
            [void]$unownedChildren.Add($o)
        }
        $terminalInFlight = Get-JArray
        foreach ($r in $ownedInFlight) {
            $t = Get-TaskById $Tasks ([string](Get-JField $r 'id'))
            if ($null -eq $t) { continue }
            $st = Get-JPath $t @('current_state', 'state')
            if ($st -ceq 'done' -or $st -ceq 'failed') {
                $o = Get-JObject
                $o['id'] = Get-JField $t 'id'
                $o['state'] = $st
                [void]$terminalInFlight.Add($o)
            }
        }

        function Join-IdList {
            param($List, [string]$Key = 'id')
            $parts = @()
            foreach ($e in $List) { $parts += [string](Get-JField $e $Key) }
            return [string]::Join(', ', $parts)
        }
        function Join-IdStateList {
            param($List)
            $parts = @()
            foreach ($e in $List) { $parts += ([string](Get-JField $e 'id') + '=' + [string](Get-JField $e 'state')) }
            return [string]::Join(', ', $parts)
        }

        $strict = Get-JArray
        if ((Get-JField $Backlog 'present') -ne $true) {
            $o = Get-JObject; $o['kind'] = 'missing_backlog'; $o['ids'] = Get-JArray
            $o['reason'] = 'missing structured backlog'; [void]$strict.Add($o)
        }
        if ($unstructuredCurrent -gt 0) {
            $o = Get-JObject; $o['kind'] = 'unstructured_current'; $o['ids'] = Get-JArray
            $o['reason'] = 'unstructured current backlog row'; [void]$strict.Add($o)
        }
        if ($orphanInFlight.Count -gt 0) {
            $ids = Get-JArray; foreach ($e in $orphanInFlight) { [void]$ids.Add((Get-JField $e 'id')) }
            $o = Get-JObject; $o['kind'] = 'orphan_in_flight'; $o['ids'] = $ids
            $o['reason'] = 'in-flight backlog item has no child metadata: ' + (Join-IdList $orphanInFlight)
            [void]$strict.Add($o)
        }
        if ($unownedChildren.Count -gt 0) {
            $ids = Get-JArray; foreach ($e in $unownedChildren) { [void]$ids.Add((Get-JField $e 'id')) }
            $o = Get-JObject; $o['kind'] = 'unowned_current'; $o['ids'] = $ids
            $o['reason'] = 'live child state has no in-flight backlog item: ' + (Join-IdStateList $unownedChildren)
            [void]$strict.Add($o)
        }
        if ($terminalInFlight.Count -gt 0) {
            $ids = Get-JArray; foreach ($e in $terminalInFlight) { [void]$ids.Add((Get-JField $e 'id')) }
            $o = Get-JObject; $o['kind'] = 'terminal_in_flight'; $o['ids'] = $ids
            $o['reason'] = 'in-flight backlog item has terminal child state: ' + (Join-IdStateList $terminalInFlight)
            [void]$strict.Add($o)
        }

        $activeAll = Get-JArray
        foreach ($r in $ownedInFlight) {
            if ((Get-JField $r 'current_role') -ceq 'program') { continue }
            $t = Get-TaskById $Tasks ([string](Get-JField $r 'id'))
            if ($null -eq $t) { continue }
            if ((Get-JPath $t @('current_state', 'state')) -cne 'working') { continue }
            $o = Get-JObject
            $o['id'] = Get-JField $t 'id'
            $o['kind'] = Get-JField $t 'kind'
            $o['state'] = Get-JPath $t @('current_state', 'state')
            $o['source'] = Get-JPath $t @('current_state', 'source')
            $detail = Get-JPath $t @('current_state', 'detail')
            if ($null -eq $detail) { $detail = '' }
            $o['doing'] = Get-Truncated $detail 120
            [void]$activeAll.Add($o)
        }

        $decisionsAll = Get-JArray
        foreach ($h in $captainHolds) { [void]$decisionsAll.Add($h) }
        foreach ($t in $Tasks) {
            foreach ($d in (Get-JList (Get-JPath $t @('hints', 'open_decisions')))) {
                $o = Get-JObject
                $o['id'] = Get-JField $t 'id'
                $o['key'] = Get-JField $d 'key'
                $o['verb'] = Get-JField $d 'verb'
                $o['summary'] = Get-Truncated (Get-JField $d 'summary') 160
                $o['reason'] = $null
                $o['source'] = 'status'
                [void]$decisionsAll.Add($o)
            }
        }

        $holdsAll = Get-JArray
        foreach ($r in $queuedAll) {
            $unresolved = Get-JList (Get-JField $r 'unresolved_blocker_ids')
            $holdReason = Get-JField $r 'hold_reason'
            $holdKind = Get-JField $r 'hold_kind'
            if (-not ($unresolved.Count -gt 0 -or ($null -ne $holdReason -and $null -ne $holdKind))) { continue }
            $joined = [string]::Join(',', @($unresolved))
            $o = Get-JObject
            $o['id'] = Get-Truncated (Get-JField $r 'id') 120
            $o['title'] = Get-Truncated (Get-JField $r 'title') 90
            $o['blocked_by'] = if ($joined -eq '') { $null } else { Get-Truncated $joined 120 }
            $ids = Get-JArray; foreach ($b in (Get-JList (Get-JField $r 'blocked_by_ids'))) { [void]$ids.Add((Get-Truncated $b 120)) }
            $o['blocked_by_ids'] = $ids
            $uids = Get-JArray; foreach ($b in $unresolved) { [void]$uids.Add((Get-Truncated $b 120)) }
            $o['unresolved_blocker_ids'] = $uids
            $reason = if ($null -ne $holdReason) { $holdReason }
            elseif ($null -ne (Get-JField $r 'blocked_reason')) { Get-JField $r 'blocked_reason' }
            else { 'blocked' }
            $o['reason'] = Get-Truncated $reason 120
            $o['source'] = 'backlog'
            [void]$holdsAll.Add($o)
        }
        foreach ($r in $ownedInFlight) {
            $t = Get-TaskById $Tasks ([string](Get-JField $r 'id'))
            if ($null -eq $t) { continue }
            $st = Get-JPath $t @('current_state', 'state')
            if ($st -cne 'parked' -and $st -cne 'paused' -and $st -cne 'blocked') { continue }
            if ($null -ne (Get-JField $r 'hold_reason') -and $null -ne (Get-JField $r 'hold_kind')) { continue }
            # `.backlog.title` on a raw task row is null here: task_json_lines does
            # not carry a backlog field, so this always falls through to the id.
            $title = Get-JPath $t @('backlog', 'title')
            if ($null -eq $title) { $title = Get-JField $t 'id' }
            $o = Get-JObject
            $o['id'] = Get-JField $t 'id'
            $o['title'] = Get-Truncated $title 90
            $o['blocked_by'] = $null
            $o['blocked_by_ids'] = Get-JArray
            $o['unresolved_blocker_ids'] = Get-JArray
            $detail = Get-JPath $t @('current_state', 'detail')
            if ($null -eq $detail -or $detail -eq '') { $detail = $st }
            $o['reason'] = Get-Truncated $detail 120
            $o['source'] = 'child-state'
            [void]$holdsAll.Add($o)
        }

        $valid = ((Get-JField $Backlog 'present') -eq $true -and $unstructuredCurrent -eq 0 -and
            $unknownChildren.Count -eq 0 -and $orphanInFlight.Count -eq 0 -and
            $unownedChildren.Count -eq 0 -and $terminalInFlight.Count -eq 0)
        $reason = if ($strict.Count -gt 0) { Get-JField $strict[0] 'reason' }
        elseif ($unknownChildren.Count -gt 0) { 'child current state unavailable: ' + (Join-IdList $unknownChildren) }
        else { $null }
        $invalidity = Get-JObject
        if ($strict.Count -gt 0) {
            $invalidity['kind'] = Get-JField $strict[0] 'kind'
            $invalidity['ids'] = Get-JField $strict[0] 'ids'
        } elseif ($unknownChildren.Count -gt 0) {
            $ids = Get-JArray; foreach ($e in $unknownChildren) { [void]$ids.Add((Get-JField $e 'id')) }
            $invalidity['kind'] = 'child_current_unavailable'
            $invalidity['ids'] = $ids
        } else {
            $invalidity['kind'] = $null
            $invalidity['ids'] = Get-JArray
        }

        $hasCaptainDecision = $false
        foreach ($d in $decisionsAll) {
            $v = Get-JField $d 'verb'
            if ($v -ceq 'needs-decision' -or $v -ceq 'captain-hold') { $hasCaptainDecision = $true; break }
        }
        $state = if (-not $valid) { 'unknown' }
        elseif ($hasCaptainDecision) { 'captain_decision' }
        elseif ($activeAll.Count -gt 0) { 'active_child_work' }
        elseif ($holdsAll.Count -gt 0) { 'externally_held' }
        else { 'no_active_work' }

        function Get-Head {
            param($List, [int]$N)
            $out = Get-JArray
            $i = 0
            foreach ($e in $List) { if ($i -ge $N) { break }; [void]$out.Add($e); $i++ }
            return , $out
        }

        $queuedOut = Get-JArray
        foreach ($r in (Get-Head $queuedAll $queuedN)) {
            $o = Get-JObject
            $o['id'] = Get-Truncated (Get-JField $r 'id') 120
            $o['title'] = Get-Truncated (Get-JField $r 'title') 120
            $o['blocked_by'] = if ($null -eq (Get-JField $r 'blocked_by')) { $null } else { Get-Truncated (Get-JField $r 'blocked_by') 120 }
            $ids = Get-JArray; foreach ($b in (Get-JList (Get-JField $r 'blocked_by_ids'))) { [void]$ids.Add((Get-Truncated $b 120)) }
            $o['blocked_by_ids'] = $ids
            $uids = Get-JArray; foreach ($b in (Get-JList (Get-JField $r 'unresolved_blocker_ids'))) { [void]$uids.Add((Get-Truncated $b 120)) }
            $o['unresolved_blocker_ids'] = $uids
            $o['blocked_reason'] = if ($null -eq (Get-JField $r 'blocked_reason')) { $null } else { Get-Truncated (Get-JField $r 'blocked_reason') 160 }
            $o['hold_reason'] = if ($null -eq (Get-JField $r 'hold_reason')) { $null } else { Get-Truncated (Get-JField $r 'hold_reason') 160 }
            $o['hold_kind'] = if ($null -eq (Get-JField $r 'hold_kind')) { $null } else { Get-Truncated (Get-JField $r 'hold_kind') 40 }
            $o['captain_actionable'] = if ($null -eq (Get-JField $r 'captain_actionable')) { $false } else { Get-JField $r 'captain_actionable' }
            $o['repo'] = if ($null -eq (Get-JField $r 'repo')) { $null } else { Get-Truncated (Get-JField $r 'repo') 120 }
            $o['kind'] = if ($null -eq (Get-JField $r 'kind')) { $null } else { Get-Truncated (Get-JField $r 'kind') 40 }
            [void]$queuedOut.Add($o)
        }

        $endpointsOut = Get-JArray
        foreach ($t in (Get-Head $Tasks $childN)) {
            $ep = Get-JObject
            foreach ($k in (Get-JField $t 'endpoint').Keys) { $ep[$k] = (Get-JField $t 'endpoint')[$k] }
            $tgt = Get-JField $ep 'target'
            $ep['target'] = if ($null -eq $tgt) { $null } else { Get-Truncated $tgt 240 }
            $o = Get-JObject
            $o['id'] = Get-JField $t 'id'
            $o['state'] = Get-JPath $t @('current_state', 'state')
            $o['source'] = Get-JPath $t @('current_state', 'source')
            $o['endpoint'] = $ep
            [void]$endpointsOut.Add($o)
        }

        $counts = Get-JObject
        $counts['active_children'] = $activeAll.Count
        $counts['decisions_open'] = $decisionsAll.Count
        $counts['holds'] = $holdsAll.Count
        $counts['queued'] = $queuedAll.Count
        $counts['landed'] = $landedSorted.Count
        $counts['endpoints'] = $Tasks.Count

        $omitted = Get-JArray
        foreach ($pair in @(
                @('active_children', $activeAll.Count, $childN),
                @('decisions_open', $decisionsAll.Count, $decisionsN),
                @('queued', $queuedAll.Count, $queuedN),
                @('endpoints', $Tasks.Count, $childN))) {
            if ([int]$pair[1] -gt [int]$pair[2]) {
                $o = Get-JObject; $o['surface'] = $pair[0]; $o['count'] = [int]$pair[1] - [int]$pair[2]
                [void]$omitted.Add($o)
            }
        }
        if ($landedN -gt 0 -and $landedSorted.Count -gt $landedN) {
            $o = Get-JObject; $o['surface'] = 'landed'; $o['count'] = $landedSorted.Count - $landedN
            [void]$omitted.Add($o)
        }

        $result = Get-JObject
        $result['schema'] = 'fm-secondmate-home-summary.v1'
        $result['generated'] = $snapshotNow
        $result['home'] = $fmHome
        $result['valid'] = $valid
        $result['reason'] = $reason
        $result['invalidity'] = $invalidity
        $result['state'] = $state
        $result['active_children'] = Get-Head $activeAll $childN
        $result['decisions_open'] = Get-Head $decisionsAll $decisionsN
        $result['holds'] = Get-Head $holdsAll $queuedN
        $result['queued'] = $queuedOut
        $result['landed'] = if ($landedN -eq 0) { $landedSorted } else { Get-Head $landedSorted $landedN }
        $result['endpoints'] = $endpointsOut
        $result['counts'] = $counts
        $result['omitted'] = $omitted
        return $result
    }

    # =========================================================================
    # bounded reads
    # =========================================================================

    # The bash counts LINES with `awk END{print NR}` over `printf '%s\n' "$c"`,
    # which counts one EXTRA line when $c already ends in a newline. That inflated
    # count is what decides the "line_limit" disclosure, so it is reproduced.
    function Get-AwkLineCount {
        param([string]$Content)
        if ($Content -eq '') { return 0 }
        return (($Content + "`n").Split("`n").Length - 1)
    }

    function Get-HeadLineText {
        param([string]$Content, [int]$N)
        if ($Content -eq '') { return '' }
        $lines = ($Content + "`n").Split("`n")
        $take = [Math]::Min($N, $lines.Length - 1)
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $take; $i++) { [void]$sb.Append($lines[$i]).Append("`n") }
        # `$( ... )` strips the trailing newlines the pipeline produced.
        return $sb.ToString().TrimEnd("`n")
    }

    function Get-TailLineText {
        param([string]$Content, [int]$N)
        if ($Content -eq '') { return '' }
        $lines = ($Content + "`n").Split("`n")
        $count = $lines.Length - 1
        $start = [Math]::Max(0, $count - $N)
        $sb = [System.Text.StringBuilder]::new()
        for ($i = $start; $i -lt $count; $i++) { [void]$sb.Append($lines[$i]).Append("`n") }
        return $sb.ToString().TrimEnd("`n")
    }

    function Get-RegistrySecondmateJson {
        $reg = Join-Path $dataDir 'secondmates.md'
        $regNative = ConvertTo-FmNativePath $reg

        function Get-RegistryAbsentJson {
            $o = Get-JObject
            $o['present'] = $false; $o['available'] = $true; $o['complete'] = $true; $o['reason'] = $null
            $o['provenance'] = 'registered-table'; $o['path'] = $reg
            $fr = Get-JObject; $fr['status'] = 'fresh'; $fr['observed_at'] = $snapshotNow
            $o['freshness'] = $fr
            $o['records'] = Get-JArray
            $o['input_truncated'] = $false; $o['records_truncated'] = $false
            $o['reasons'] = Get-JArray; $o['lines_in_window'] = 0; $o['records_in_window'] = 0
            return $o
        }
        function Get-RegistryUnavailableJson {
            param([string]$Reason)
            $o = Get-JObject
            $o['present'] = $true; $o['available'] = $false; $o['complete'] = $false; $o['reason'] = $Reason
            $o['provenance'] = 'registered-table'; $o['path'] = $reg
            $fr = Get-JObject; $fr['status'] = 'unavailable'; $fr['observed_at'] = $snapshotNow
            $o['freshness'] = $fr
            $o['records'] = Get-JArray
            $o['input_truncated'] = $false; $o['records_truncated'] = $false
            $rs = Get-JArray; [void]$rs.Add($Reason); $o['reasons'] = $rs
            $o['lines_in_window'] = 0; $o['records_in_window'] = 0
            return $o
        }

        if (-not [System.IO.File]::Exists($regNative)) { return (Get-RegistryAbsentJson) }

        $maxBytes = [int]$bounds['FM_SNAPSHOT_REGISTRY_BYTES']
        $maxLines = [int]$bounds['FM_SNAPSHOT_REGISTRY_LINES']
        $maxRecords = [int]$bounds['FM_SNAPSHOT_REGISTRY_RECORDS']

        $bytes = $null
        try { $bytes = [System.IO.File]::ReadAllBytes($regNative) } catch { $bytes = $null }
        # Divergence 2 in this file's header: readability is decided by the read
        # itself, because chmod is inert on this platform.
        if ($null -eq $bytes) { return (Get-RegistryUnavailableJson 'registered secondmate table is unreadable') }

        # `head -c $((max+1))` then a byte-length test, with the \036 guard the
        # bash uses so trailing newlines are NOT stripped.
        $head = if ($bytes.Length -gt ($maxBytes + 1)) { $bytes[0..$maxBytes] } else { $bytes }
        $byteTruncated = $head.Length -gt $maxBytes
        $keep = if ($byteTruncated) { $maxBytes } else { $head.Length }
        $content = [System.Text.Encoding]::UTF8.GetString($head, 0, $keep) -replace "`r`n", "`n"
        if ($byteTruncated) {
            $lastLf = $content.LastIndexOf("`n")
            $content = if ($lastLf -ge 0) { $content.Substring(0, $lastLf) } else { '' }
        }
        $lines = Get-AwkLineCount $content
        $lineTruncated = $lines -gt $maxLines
        $window = Get-HeadLineText $content $maxLines
        $linesInWindow = Get-AwkLineCount $window

        $parsed = Get-JArray
        if ($window -ne '') {
            foreach ($line in $window.Split("`n")) {
                if (-not $line.StartsWith('- ', [System.StringComparison]::Ordinal)) { continue }
                $idm = [regex]::Match($line, "^- (?<id>[^$NSP]+)")
                if (-not $idm.Success) { continue }
                $hm = [regex]::Match($line,
                    "^.*\(home:$SP*(?<home>[^;)]*);$SP*scope:$SP*.*;$SP*projects:$SP*[^;)]*;$SP*added$SP+[0-9]{4}-[0-9]{2}-[0-9]{2}\)$SP*$")
                # A line that does not carry the structured suffix is DROPPED, not
                # reported. That is jq's `(capture(...)?) as $home | ...`: on no
                # match `capture` yields NOTHING, so `as` iterates zero times and
                # the whole record never reaches the object constructor. Verified
                # against jq on this host, because the alternative reading - bind
                # null and report "registry entry has no home" - is the obvious one
                # and is wrong. That message is reachable only through the OTHER
                # arm: a suffix that matches with an EMPTY home field.
                if (-not $hm.Success) { continue }
                $o = Get-JObject
                $o['id'] = $idm.Groups['id'].Value
                $o['home'] = $hm.Groups['home'].Value
                $o['registered'] = $true
                $o['registry_error'] = if ($hm.Groups['home'].Value.Length -eq 0) {
                    'registry entry has no home'
                } else { $null }
                [void]$parsed.Add($o)
            }
        }
        # `group_by(.id) | map(...)`: group_by SORTS by the key, so the records
        # come back id-ordered, and a duplicate id collapses to its first record
        # carrying the duplicate error.
        $grouped = Get-JArray
        $byId = [ordered]@{}
        foreach ($p in $parsed) {
            $id = [string](Get-JField $p 'id')
            if (-not $byId.Contains($id)) { $byId[$id] = Get-JArray }
            [void]$byId[$id].Add($p)
        }
        foreach ($id in (Get-JSorted @($byId.Keys) { param($k) [string]$k })) {
            $group = $byId[$id]
            $first = $group[0]
            if ($group.Count -gt 1) {
                $copy = Get-JObject
                foreach ($k in $first.Keys) { $copy[$k] = $first[$k] }
                $copy['registry_error'] = 'duplicate secondmate id in registry'
                [void]$grouped.Add($copy)
            } else {
                [void]$grouped.Add($first)
            }
        }

        $recordsInWindow = $grouped.Count
        $recordsTruncated = $recordsInWindow -gt $maxRecords
        $records = Get-JArray
        $i = 0
        foreach ($g in $grouped) { if ($i -ge $maxRecords) { break }; [void]$records.Add($g); $i++ }

        $o = Get-JObject
        $o['present'] = $true
        $o['available'] = $true
        $o['reason'] = $null
        $o['provenance'] = 'registered-table'
        $o['path'] = $reg
        $fr = Get-JObject; $fr['status'] = 'fresh'; $fr['observed_at'] = $snapshotNow
        $o['freshness'] = $fr
        $o['records'] = $records
        $o['input_truncated'] = ($byteTruncated -or $lineTruncated)
        $o['records_truncated'] = $recordsTruncated
        $o['complete'] = (-not ($byteTruncated -or $lineTruncated -or $recordsTruncated))
        $reasons = Get-JArray
        if ($byteTruncated) { [void]$reasons.Add('byte_limit') }
        if ($lineTruncated) { [void]$reasons.Add('line_limit') }
        if ($recordsTruncated) { [void]$reasons.Add('record_limit') }
        $o['reasons'] = $reasons
        $o['lines_in_window'] = $linesInWindow
        $o['records_in_window'] = $recordsInWindow
        return $o
    }

    function Get-BoundedParentActivityJson {
        param([AllowEmptyString()][AllowNull()][string]$Path)

        $o = Get-JObject
        if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) {
            $o['records'] = Get-JArray; $o['available'] = $true
            $o['input_truncated'] = $false; $o['retained_truncated'] = $false
            $o['reasons'] = Get-JArray; $o['lines_in_window'] = 0; $o['records_in_window'] = 0
            return $o
        }

        $maxBytes = [int]$bounds['FM_SNAPSHOT_PARENT_ACTIVITY_BYTES']
        $maxLines = [int]$bounds['FM_SNAPSHOT_PARENT_ACTIVITY_LINES']
        $maxRecords = [int]$bounds['FM_SNAPSHOT_PARENT_ACTIVITIES']

        $native = ConvertTo-FmNativePath $Path
        $bytes = $null
        try { $bytes = [System.IO.File]::ReadAllBytes($native) } catch { $bytes = $null }
        if ($null -eq $bytes) {
            $o['records'] = Get-JArray; $o['available'] = $false
            $o['input_truncated'] = $false; $o['retained_truncated'] = $false
            $rs = Get-JArray; [void]$rs.Add('read_failed'); $o['reasons'] = $rs
            $o['lines_in_window'] = 0; $o['records_in_window'] = 0
            return $o
        }
        $size = $bytes.Length
        $start = [Math]::Max(0, $size - $maxBytes)
        $content = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $size - $start) -replace "`r`n", "`n"
        # `$( tail -c ... )` DOES strip trailing newlines here (no \036 guard).
        $content = $content.TrimEnd("`n")
        $byteTruncated = $size -gt $maxBytes
        if ($byteTruncated) {
            $firstLf = $content.IndexOf("`n")
            $content = if ($firstLf -ge 0) { $content.Substring($firstLf + 1) } else { '' }
        }
        $linesInChunk = Get-AwkLineCount $content
        $lineTruncated = $linesInChunk -gt $maxLines
        $window = Get-TailLineText $content $maxLines
        $linesInWindow = Get-AwkLineCount $window

        $activities = ConvertFrom-KeyedTsv (Get-FmStatusOpenActivities -InputText $window)
        $recordsInWindow = $activities.Count
        $retainedTruncated = $recordsInWindow -gt $maxRecords
        $records = Get-JArray
        $skip = [Math]::Max(0, $recordsInWindow - $maxRecords)
        for ($i = $skip; $i -lt $recordsInWindow; $i++) { [void]$records.Add($activities[$i]) }

        $o['records'] = $records
        $o['available'] = $true
        $o['input_truncated'] = ($byteTruncated -or $lineTruncated)
        $o['retained_truncated'] = $retainedTruncated
        $reasons = Get-JArray
        if ($byteTruncated) { [void]$reasons.Add('byte_limit') }
        if ($lineTruncated) { [void]$reasons.Add('line_limit') }
        if ($retainedTruncated) { [void]$reasons.Add('activity_limit') }
        $o['reasons'] = $reasons
        $o['lines_in_window'] = $linesInWindow
        $o['records_in_window'] = $recordsInWindow
        return $o
    }

    # =========================================================================
    # untrusted supplements: terminal capture and parent-event reconciliation
    # =========================================================================

    function Get-TerminalEvidenceJson {
        param($Task, [AllowEmptyString()][AllowNull()][string]$Note, [bool]$EvidenceContradicts)

        function Get-TerminalNotCapturedJson {
            param([string]$Reason, [string]$Freshness = 'unknown')
            $o = Get-JObject
            $o['provenance'] = 'parent-direct-report-terminal'
            $o['trust'] = 'untrusted-supplement'
            $o['captured'] = $false
            $o['observed_at'] = $snapshotNow
            $o['freshness'] = $Freshness
            $o['reason'] = $Reason
            $o['lines'] = 0
            $o['bytes'] = 0
            $o['event_note_seen'] = $false
            $o['contradiction'] = $false
            return $o
        }

        $backend = [string](Get-JField $Task 'backend')
        $target = Get-JPath $Task @('endpoint', 'target')
        if ($null -eq $target) { $target = '' }
        $exists = Get-JPath $Task @('endpoint', 'exists')
        $expected = 'fm-' + [string](Get-JField $Task 'id')

        if ([string]::IsNullOrEmpty([string]$target) -or $exists -eq $false) {
            $reason = if ($exists -eq $false) { 'recorded endpoint is absent' } else { 'no recorded endpoint' }
            return (Get-TerminalNotCapturedJson $reason)
        }

        $capture = $null
        try {
            $capture = Get-FmBackendCapture $backend ([string]$target) `
                ([string]$bounds['FM_SNAPSHOT_TERMINAL_LINES']) $expected
        } catch { $capture = $null }
        if ($null -eq $capture) { return (Get-TerminalNotCapturedJson 'terminal capture unavailable') }

        $maxBytes = [int]$bounds['FM_SNAPSHOT_TERMINAL_BYTES']
        $out = $capture -replace "`r`n", "`n"
        $raw = [System.Text.Encoding]::UTF8.GetBytes($out)
        if ($raw.Length -gt $maxBytes) { $out = [System.Text.Encoding]::UTF8.GetString($raw, 0, $maxBytes) }
        $clean = Get-TailLineText $out ([int]$bounds['FM_SNAPSHOT_TERMINAL_LINES'])
        # The perl program: strip CSI sequences, then everything outside
        # TAB/LF/CR and printable ASCII.
        $clean = [regex]::Replace($clean, "`e\[[0-?]*[ -/]*[@-~]", '')
        $clean = [regex]::Replace($clean, "[^\t\n\r\x20-\x7E]", '')

        $o = Get-JObject
        $o['provenance'] = 'parent-direct-report-terminal'
        $o['trust'] = 'untrusted-supplement'
        $o['captured'] = $true
        $o['observed_at'] = $snapshotNow
        $o['freshness'] = 'fresh'
        $o['reason'] = $null
        $o['lines'] = Get-AwkLineCount $clean
        $o['bytes'] = [System.Text.Encoding]::UTF8.GetByteCount($clean)
        $seen = (-not [string]::IsNullOrEmpty($Note)) -and $clean.Contains([string]$Note)
        $o['event_note_seen'] = $seen
        $o['contradiction'] = ($seen -and $EvidenceContradicts)
        return $o
    }

    function Get-ParentEvidenceReconciliationJson {
        param($Summary, $Activities, $Decisions)

        function Test-Keyed {
            param($Key)
            return ($null -ne $Key -and [string]$Key -ne '' -and [string]$Key -cne 'default')
        }
        function Get-ReconciliationResult {
            param($EventRecord, $MatchList, [bool]$Complete, $Surface)
            $o = Get-JObject
            foreach ($k in $EventRecord.Keys) { $o[$k] = $EventRecord[$k] }
            $keyed = Test-Keyed (Get-JField $EventRecord 'key')
            $o['verdict'] = if (-not $keyed) { 'inconclusive' }
            elseif ($MatchList.Count -gt 0) { 'corroborates' }
            elseif ($Complete) { 'contradicts' }
            else { 'inconclusive' }
            $o['compared_to'] = $Surface
            $o['matched'] = if ($keyed -and $MatchList.Count -gt 0) { $MatchList[0] } else { $null }
            return $o
        }
        function Get-InconclusiveResult {
            param($EventRecord)
            $o = Get-JObject
            foreach ($k in $EventRecord.Keys) { $o[$k] = $EventRecord[$k] }
            $o['verdict'] = 'inconclusive'
            $o['compared_to'] = $null
            $o['matched'] = $null
            return $o
        }

        $activeChildren = Get-JList (Get-JField $Summary 'active_children')
        $holds = Get-JList (Get-JField $Summary 'holds')
        $decisionsOpen = Get-JList (Get-JField $Summary 'decisions_open')
        $counts = Get-JField $Summary 'counts'
        $activeComplete = ((Get-JField $counts 'active_children') -eq $activeChildren.Count)
        $holdsComplete = ((Get-JField $counts 'holds') -eq $holds.Count)
        $decisionsComplete = ((Get-JField $counts 'decisions_open') -eq $decisionsOpen.Count)

        $activityResults = Get-JArray
        foreach ($e in (Get-JList $Activities)) {
            $key = Get-JField $e 'key'
            $keyed = Test-Keyed $key
            if ((Get-JField $e 'verb') -ceq 'working') {
                $matched = Get-JArray
                foreach ($c in $activeChildren) {
                    if ($keyed -and (Get-JField $c 'id') -cne $key) { continue }
                    $m = Get-JObject
                    $m['surface'] = 'active_children'; $m['id'] = Get-JField $c 'id'
                    $m['key'] = $null; $m['verb'] = 'working'
                    [void]$matched.Add($m)
                }
                [void]$activityResults.Add((Get-ReconciliationResult $e $matched $activeComplete 'active_children'))
            } elseif ((Get-JField $e 'verb') -ceq 'paused') {
                $matched = Get-JArray
                foreach ($h in $holds) {
                    if ($keyed -and (Get-JField $h 'id') -cne $key -and (Get-JField $h 'blocked_by') -cne $key) { continue }
                    $m = Get-JObject
                    $m['surface'] = 'holds'; $m['id'] = Get-JField $h 'id'
                    $m['key'] = Get-JField $h 'blocked_by'; $m['verb'] = 'paused'
                    [void]$matched.Add($m)
                }
                [void]$activityResults.Add((Get-ReconciliationResult $e $matched $holdsComplete 'holds'))
            } else {
                [void]$activityResults.Add((Get-InconclusiveResult $e))
            }
        }

        $decisionResults = Get-JArray
        foreach ($e in (Get-JList $Decisions)) {
            $key = Get-JField $e 'key'
            $keyed = Test-Keyed $key
            if ((Get-JField $e 'verb') -ceq 'needs-decision') {
                $matched = Get-JArray
                foreach ($d in $decisionsOpen) {
                    if ((Get-JField $d 'verb') -cne 'needs-decision') { continue }
                    if ($keyed -and (Get-JField $d 'key') -cne $key) { continue }
                    $m = Get-JObject
                    $m['surface'] = 'decisions_open'; $m['id'] = Get-JField $d 'id'
                    $m['key'] = Get-JField $d 'key'; $m['verb'] = Get-JField $d 'verb'
                    [void]$matched.Add($m)
                }
                [void]$decisionResults.Add((Get-ReconciliationResult $e $matched $decisionsComplete 'decisions_open'))
            } elseif ((Get-JField $e 'verb') -ceq 'blocked') {
                $matched = Get-JArray
                foreach ($d in $decisionsOpen) {
                    if ((Get-JField $d 'verb') -cne 'blocked') { continue }
                    if ($keyed -and (Get-JField $d 'key') -cne $key -and (Get-JField $d 'id') -cne $key) { continue }
                    $m = Get-JObject
                    $m['surface'] = 'decisions_open'; $m['id'] = Get-JField $d 'id'
                    $m['key'] = Get-JField $d 'key'; $m['verb'] = Get-JField $d 'verb'
                    [void]$matched.Add($m)
                }
                foreach ($h in $holds) {
                    if ($keyed -and (Get-JField $h 'id') -cne $key -and (Get-JField $h 'blocked_by') -cne $key) { continue }
                    $m = Get-JObject
                    $m['surface'] = 'holds'; $m['id'] = Get-JField $h 'id'
                    $m['key'] = Get-JField $h 'blocked_by'; $m['verb'] = 'blocked'
                    [void]$matched.Add($m)
                }
                [void]$decisionResults.Add((Get-ReconciliationResult $e $matched ($decisionsComplete -and $holdsComplete) 'decisions_open_or_holds'))
            } else {
                [void]$decisionResults.Add((Get-InconclusiveResult $e))
            }
        }

        $contradiction = $false
        $inconclusive = $false
        foreach ($r in @($activityResults) + @($decisionResults)) {
            if ((Get-JField $r 'verdict') -ceq 'contradicts') { $contradiction = $true }
            if ((Get-JField $r 'verdict') -ceq 'inconclusive') { $inconclusive = $true }
        }

        $o = Get-JObject
        $o['provenance'] = 'parent-status-keyed-fold'
        $o['trust'] = 'untrusted-supplement'
        $o['activities'] = $activityResults
        $o['decisions'] = $decisionResults
        $o['contradiction'] = $contradiction
        $o['inconclusive'] = $inconclusive
        return $o
    }

    # =========================================================================
    # registered-secondmate aggregation
    # =========================================================================

    function Get-SecondmateCurrentJson {
        param($Tasks)

        $registry = Get-RegistrySecondmateJson
        $registryRecords = Get-JList (Get-JField $registry 'records')
        $registryComplete = ((Get-JField $registry 'complete') -eq $true)
        $registeredIds = @{}
        foreach ($r in $registryRecords) { $registeredIds[[string](Get-JField $r 'id')] = $true }

        $union = Get-JArray
        foreach ($r in $registryRecords) {
            $o = Get-JObject
            foreach ($k in $r.Keys) { $o[$k] = $r[$k] }
            $parent = $null
            foreach ($t in $Tasks) { if ((Get-JField $t 'id') -ceq (Get-JField $r 'id')) { $parent = $t; break } }
            $o['parent_task'] = $parent
            [void]$union.Add($o)
        }
        foreach ($t in $Tasks) {
            if ((Get-JField $t 'kind') -cne 'secondmate') { continue }
            if ($registeredIds.ContainsKey([string](Get-JField $t 'id'))) { continue }
            $o = Get-JObject
            $o['id'] = Get-JField $t 'id'
            $o['home'] = Get-JPath $t @('paths', 'home', 'path')
            $o['registered'] = if ($registryComplete) { $false } else { $null }
            $o['registry_error'] = if ($registryComplete) { 'secondmate metadata is not registered' }
            else { 'secondmate registration is unknown because the registry read is incomplete or unavailable' }
            $o['parent_task'] = $t
            [void]$union.Add($o)
        }
        $unionSorted = Get-JSorted $union { param($u) [string](Get-JField $u 'id') }

        $totalRegistered = 0
        foreach ($u in $unionSorted) { if ((Get-JField $u 'registered') -eq $true) { $totalRegistered++ } }
        $total = $unionSorted.Count
        # `(if $cap == 0 then .records else .records[:$cap] end)` - a cap of 0
        # LIFTS the bound rather than emptying the list. Built by index rather
        # than with a PowerShell range, because `0..-1` on an empty list is a
        # descending range, not an empty one, and throws.
        $cap = [int]$boundSecondmates
        $take = if ($cap -eq 0) { $total } else { [Math]::Min($cap, $total) }
        $rows = Get-JArray
        for ($i = 0; $i -lt $take; $i++) { [void]$rows.Add($unionSorted[$i]) }
        $shown = $rows.Count
        $truncated = $total - $shown

        $records = Get-JArray
        $seenHomes = [System.Collections.Generic.List[string]]::new()

        foreach ($row in $rows) {
            $id = [string](Get-JField $row 'id')
            $homeValue = Get-JField $row 'home'
            if ($null -eq $homeValue) { $homeValue = '' }
            $homeValue = [string]$homeValue
            $registered = Get-JField $row 'registered'
            $registryError = Get-JField $row 'registry_error'
            if ($null -eq $registryError) { $registryError = '' }
            $task = Get-JField $row 'parent_task'

            $statusFile = ''
            $eventRaw = ''
            $eventNote = ''
            if ($null -ne $task) {
                $v = Get-JPath $task @('paths', 'status_log', 'path'); if ($null -ne $v) { $statusFile = [string]$v }
                $v = Get-JPath $task @('paths', 'status_log', 'last_event', 'raw'); if ($null -ne $v) { $eventRaw = [string]$v }
                $v = Get-JPath $task @('paths', 'status_log', 'last_event', 'note'); if ($null -ne $v) { $eventNote = [string]$v }
            }
            $activityScan = Get-BoundedParentActivityJson $statusFile
            $activities = Get-JField $activityScan 'records'
            $decisions = if ($null -ne $task) { Get-JList (Get-JPath $task @('hints', 'open_decisions')) } else { Get-JArray }

            $eventEpoch = Get-FileMtimeEpoch $statusFile
            $eventAge = $null
            if ($null -ne $eventEpoch) {
                $eventAge = $snapshotEpoch - $eventEpoch
                if ($eventAge -lt 0) { $eventAge = 0 }
            }

            $reason = [string]$registryError
            $summary = $null
            $summaryValid = $false
            if ($reason -eq '' -and $homeValue -eq '') { $reason = 'no recorded secondmate home' }
            if ($reason -eq '') {
                # `case "$homeValue" in /*)` - a durable record's home is stored in POSIX
                # form by the bash writers, so an MSYS `/f/...` path is what this
                # test is for. A native `F:\...` spelling is accepted too, because
                # the PowerShell writers legitimately produce it and the bash rule
                # would otherwise reject a home this world just wrote.
                if (-not ($homeValue.StartsWith('/') -or $homeValue -match '^[A-Za-z]:[\\/]')) {
                    $reason = 'invalid home: registered path is not absolute'
                }
            }
            if ($reason -eq '') {
                $validation = Resolve-FmFfSecondmateHome -Id $id -HomePath $homeValue `
                    -ActiveHome $fmHome -RepoRoot $fmRoot
                if (-not $validation.Ok) {
                    $reason = 'invalid home: ' + $validation.Error
                } else {
                    $homeValue = $validation.ValidatedHome
                    if ($seenHomes.Contains($homeValue)) {
                        $reason = 'invalid home: duplicate resolved home route'
                    } else {
                        $seenHomes.Add($homeValue)
                    }
                }
            }
            if ($reason -eq '') {
                $childEnv = [ordered]@{
                    FM_ROOT_OVERRIDE                       = $fmRoot
                    FM_HOME                                = $homeValue
                    FM_STATE_OVERRIDE                      = (Join-Path $homeValue 'state')
                    FM_DATA_OVERRIDE                       = (Join-Path $homeValue 'data')
                    FM_CONFIG_OVERRIDE                     = (Join-Path $homeValue 'config')
                    FM_PROJECTS_OVERRIDE                   = (Join-Path $homeValue 'projects')
                    FM_SNAPSHOT_NOW                        = $snapshotNow
                    FM_SNAPSHOT_NOW_EPOCH                  = [string]$snapshotEpoch
                    FM_SNAPSHOT_SECONDMATE_CHILDREN        = [string]$bounds['FM_SNAPSHOT_SECONDMATE_CHILDREN']
                    FM_SNAPSHOT_SECONDMATE_QUEUED          = [string]$bounds['FM_SNAPSHOT_SECONDMATE_QUEUED']
                    FM_SNAPSHOT_SECONDMATE_DECISIONS       = [string]$bounds['FM_SNAPSHOT_SECONDMATE_DECISIONS']
                    FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME = [string]$landedPerHome
                }
                $child = Invoke-ChildWithEnv -Name 'fm-fleet-snapshot' `
                    -Arguments @('--secondmate-home-summary') -Environment $childEnv `
                    -TimeoutSeconds ([int]$bounds['FM_SNAPSHOT_SECONDMATE_TIMEOUT'])
                if ($child.ExitCode -ne 0) {
                    $reason = if ($child.ExitCode -eq 124) { 'structured home snapshot timed out' }
                    else { 'structured home snapshot failed' }
                } else {
                    $summaryText = $child.StdOut
                    if ([System.Text.Encoding]::UTF8.GetByteCount($summaryText) -gt
                        [int]$bounds['FM_SNAPSHOT_SECONDMATE_MAX_BYTES']) {
                        $reason = 'structured home snapshot exceeded byte limit'
                    } else {
                        $ok = $false
                        try { $summary = ConvertFrom-Json $summaryText -AsHashtable; $ok = $true } catch { $ok = $false }
                        if ($ok) {
                            $ok = ((Get-JField $summary 'schema') -ceq 'fm-secondmate-home-summary.v1' -and
                                (Get-JField $summary 'home') -ceq $homeValue -and
                                (Get-JField $summary 'generated') -ceq $snapshotNow -and
                                (Get-JField $summary 'valid') -is [bool] -and
                                (Get-JField $summary 'state') -is [string] -and
                                (Get-JField $summary 'invalidity') -is [System.Collections.IDictionary] -and
                                (Get-JPath $summary @('invalidity', 'ids')) -is [System.Collections.IList] -and
                                (Get-JField $summary 'active_children') -is [System.Collections.IList] -and
                                (Get-JField $summary 'decisions_open') -is [System.Collections.IList] -and
                                (Get-JField $summary 'holds') -is [System.Collections.IList] -and
                                (Get-JField $summary 'queued') -is [System.Collections.IList] -and
                                (Get-JField $summary 'landed') -is [System.Collections.IList] -and
                                (Get-JField $summary 'endpoints') -is [System.Collections.IList] -and
                                (Get-JField $summary 'counts') -is [System.Collections.IDictionary] -and
                                (Get-JField $summary 'omitted') -is [System.Collections.IList])
                        }
                        if (-not $ok) {
                            $reason = 'structured home snapshot was malformed or stale'
                        } else {
                            $summaryValid = ((Get-JField $summary 'valid') -eq $true)
                            if (-not $summaryValid) {
                                $summaryReason = Get-JField $summary 'reason'
                                if ($null -eq $summaryReason) { $summaryReason = 'unknown reason' }
                                $summaryInvalidity = Get-JPath $summary @('invalidity', 'kind')
                                if ($null -eq $summaryInvalidity) { $summaryInvalidity = 'unknown' }
                                if ($summaryInvalidity -cne 'child_current_unavailable') {
                                    $reason = 'structured home state invalid: ' + $summaryReason
                                }
                            }
                        }
                    }
                }
            }

            if ($reason -eq '') {
                $currentReason = $null
                if (-not $summaryValid) {
                    $sr = Get-JField $summary 'reason'
                    if ($null -eq $sr) { $sr = 'unknown reason' }
                    $currentReason = 'structured home state invalid: ' + $sr
                }
                $reconciliation = Get-ParentEvidenceReconciliationJson $summary $activities $decisions
                $contradiction = ((Get-JField $reconciliation 'contradiction') -eq $true)
                $terminalContradiction = $false
                foreach ($a in (Get-JField $reconciliation 'activities')) {
                    if ((Get-JField $a 'verdict') -ceq 'contradicts' -and (Get-JField $a 'summary') -ceq $eventNote) {
                        $terminalContradiction = $true
                    }
                }
                $terminal = if ($terminalContradiction) {
                    Get-TerminalEvidenceJson $task $eventNote $true
                } else {
                    $o = Get-JObject
                    $o['provenance'] = 'parent-direct-report-terminal'
                    $o['trust'] = 'untrusted-supplement'
                    $o['captured'] = $false
                    $o['observed_at'] = $snapshotNow
                    $o['freshness'] = 'not-collected'
                    $o['reason'] = 'no useful contradiction check'
                    $o['lines'] = 0; $o['bytes'] = 0
                    $o['event_note_seen'] = $false; $o['contradiction'] = $false
                    $o
                }
                if ((Get-JField $terminal 'contradiction') -eq $true) { $contradiction = $true }

                $current = Get-JObject
                $current['state'] = Get-JField $summary 'state'
                $current['reason'] = $currentReason
                $provenance = Get-JObject
                $provenance['selected'] = 'structured-home'
                $provenance['structured_home'] = $homeValue
                $provenance['summary_valid'] = $summaryValid
                $provenance['trust'] = if ($summaryValid) { 'complete' } else { 'partial-structured' }
                $provenance['parent_event_role'] = 'historical-only'
                $freshness = Get-JObject
                $freshness['status'] = 'fresh'
                $freshness['observed_at'] = $snapshotNow
                $freshness['age_seconds'] = 0
                $parentEvent = Get-JObject
                $parentEvent['raw'] = $eventRaw
                $parentEvent['note'] = $eventNote
                $parentEvent['age_seconds'] = $eventAge
                $parentEvent['open_activities'] = $activities
                $parentEvent['open_decisions'] = $decisions
                $parentEvent['activity_scan'] = $activityScan
                $parentEvent['reconciliation'] = $reconciliation

                $record = Get-JObject
                $record['id'] = $id
                $record['home'] = $homeValue
                $record['registered'] = $registered
                $record['current'] = $current
                $record['invalidity'] = Get-JField $summary 'invalidity'
                $record['provenance'] = $provenance
                $record['freshness'] = $freshness
                $record['active_children'] = Get-JField $summary 'active_children'
                $record['decisions_open'] = Get-JField $summary 'decisions_open'
                $record['holds'] = Get-JField $summary 'holds'
                $record['queued'] = Get-JField $summary 'queued'
                $record['landed'] = Get-JField $summary 'landed'
                $record['endpoints'] = Get-JField $summary 'endpoints'
                $record['counts'] = Get-JField $summary 'counts'
                $record['omitted'] = Get-JField $summary 'omitted'
                $record['parent_event'] = $parentEvent
                $record['terminal_evidence'] = $terminal
                $record['contradiction'] = $contradiction
                [void]$records.Add($record)
                continue
            }

            $provenanceName = if ($eventRaw -ne '') { 'parent-event-fallback' } else { 'unknown' }
            $freshnessName = if ($eventRaw -ne '') { 'historical-event' } else { 'unknown' }
            $terminal = if ($eventRaw -ne '') {
                Get-TerminalEvidenceJson $task $eventNote $false
            } else {
                $o = Get-JObject
                $o['provenance'] = 'parent-direct-report-terminal'
                $o['trust'] = 'untrusted-supplement'
                $o['captured'] = $false
                $o['observed_at'] = $snapshotNow
                $o['freshness'] = 'not-collected'
                $o['reason'] = 'no parent event to compare'
                $o['lines'] = 0; $o['bytes'] = 0
                $o['event_note_seen'] = $false; $o['contradiction'] = $false
                $o
            }

            $current = Get-JObject
            $current['state'] = 'unknown'
            $current['reason'] = $reason
            $provenance = Get-JObject
            $provenance['selected'] = $provenanceName
            $provenance['structured_home'] = if ($homeValue -eq '') { $null } else { $homeValue }
            $provenance['parent_event_role'] = 'fallback-only-not-current'
            $freshness = Get-JObject
            $freshness['status'] = $freshnessName
            $freshness['observed_at'] = $snapshotNow
            $freshness['age_seconds'] = $eventAge
            $counts = Get-JObject
            foreach ($k in @('active_children', 'decisions_open', 'holds', 'queued', 'landed', 'endpoints')) {
                $counts[$k] = 0
            }
            $parentEvent = Get-JObject
            $parentEvent['raw'] = $eventRaw
            $parentEvent['note'] = $eventNote
            $parentEvent['age_seconds'] = $eventAge
            $parentEvent['open_activities'] = $activities
            $parentEvent['open_decisions'] = $decisions
            $parentEvent['activity_scan'] = $activityScan

            $record = Get-JObject
            $record['id'] = $id
            $record['home'] = if ($homeValue -eq '') { $null } else { $homeValue }
            $record['registered'] = $registered
            $record['current'] = $current
            $record['invalidity'] = $null
            $record['provenance'] = $provenance
            $record['freshness'] = $freshness
            $record['active_children'] = Get-JArray
            $record['decisions_open'] = Get-JArray
            $record['holds'] = Get-JArray
            $record['queued'] = Get-JArray
            $record['landed'] = Get-JArray
            $record['endpoints'] = Get-JArray
            $record['counts'] = $counts
            $record['omitted'] = Get-JArray
            $record['parent_event'] = $parentEvent
            $record['terminal_evidence'] = $terminal
            $record['contradiction'] = $false
            [void]$records.Add($record)
        }

        $o = Get-JObject
        $o['registry'] = $registry
        $o['records'] = $records
        $o['total_registered'] = $totalRegistered
        $o['total'] = $total
        $o['shown'] = $shown
        $o['truncated'] = $truncated
        return $o
    }

    function Get-SecondmateLandedJson {
        param($Current)
        $records = Get-JArray
        $truncated = Get-JArray
        $unreadable = Get-JArray
        $partial = Get-JArray
        foreach ($mate in (Get-JList (Get-JField $Current 'records'))) {
            $selected = Get-JPath $mate @('provenance', 'selected')
            $state = Get-JPath $mate @('current', 'state')
            $homeValue = Get-JField $mate 'home'
            if ($selected -ceq 'structured-home') {
                foreach ($l in (Get-JList (Get-JField $mate 'landed'))) {
                    $o = Get-JObject
                    foreach ($k in $l.Keys) { $o[$k] = $l[$k] }
                    $o['home'] = $homeValue
                    $o['home_id'] = Get-JField $mate 'id'
                    [void]$records.Add($o)
                }
                if ((Get-JPath $mate @('counts', 'landed')) -gt (Get-JList (Get-JField $mate 'landed')).Count) {
                    [void]$truncated.Add($homeValue)
                }
            }
            if ($state -ceq 'unknown' -and $selected -cne 'structured-home') {
                [void]$unreadable.Add(($(if ($null -ne $homeValue) { $homeValue } else { '<' + [string](Get-JField $mate 'id') + ': unavailable>' })))
            }
            if ($state -ceq 'unknown' -and $selected -ceq 'structured-home') {
                [void]$partial.Add(($(if ($null -ne $homeValue) { $homeValue } else { '<' + [string](Get-JField $mate 'id') + ': partial>' })))
            }
        }
        $sortedRecords = Get-JArray
        $ordered = Get-JSorted $records {
            param($e)
            $d = Get-JPath $e @('completion', 'date')
            $d = if ($null -eq $d) { '' } else { [string]$d }
            return ($d + [char]0 + [string](Get-JField $e 'id'))
        }
        for ($i = $ordered.Count - 1; $i -ge 0; $i--) { [void]$sortedRecords.Add($ordered[$i]) }

        $o = Get-JObject
        $o['records'] = $sortedRecords
        $o['truncated'] = $truncated
        $o['unreadable'] = $unreadable
        $o['partial'] = $partial
        return $o
    }

    function Get-ScoutReportJson {
        $reports = Get-JArray
        $dataNative = ConvertTo-FmNativePath $dataDir
        if (-not (Test-Path -LiteralPath $dataNative -PathType Container)) { return , $reports }
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($dir in [System.IO.Directory]::EnumerateDirectories($dataNative)) {
            $candidate = Join-Path $dir 'report.md'
            if ([System.IO.File]::Exists($candidate)) { $found.Add($candidate) }
        }
        $found.Sort([System.StringComparer]::Ordinal)
        foreach ($report in $found) {
            $o = Get-JObject
            $o['id'] = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($report))
            $o['path'] = $report
            [void]$reports.Add($o)
        }
        return , (Get-JSorted $reports { param($r) [string](Get-JField $r 'id') })
    }

    # =========================================================================
    # assembly
    # =========================================================================

    $backlogJson = Get-BacklogJson $backlogPath
    $tasksJson = Get-TaskListJson

    if ($outputMode -ceq 'secondmate-home-summary') {
        Write-FmOut (ConvertTo-JqJson (Get-SecondmateHomeSummaryJson $backlogJson $tasksJson))
        Exit-FmScript 0
    }

    $scoutReports = Get-ScoutReportJson
    $mainInventory = Get-MainInventoryJson $backlogJson $tasksJson
    $secondmateCurrent = Get-SecondmateCurrentJson $tasksJson
    $secondmateLanded = Get-SecondmateLandedJson $secondmateCurrent

    $backlogById = @{}
    foreach ($r in (Get-JList (Get-JField $backlogJson 'records'))) {
        if ((Get-JField $r 'structured') -ne $true) { continue }
        $id = [string](Get-JField $r 'id')
        if (-not $backlogById.ContainsKey($id)) { $backlogById[$id] = $r }
    }
    $taskById = @{}
    foreach ($t in $tasksJson) { $taskById[[string](Get-JField $t 'id')] = $t }

    $tasksOut = Get-JArray
    foreach ($t in $tasksJson) {
        $o = Get-JObject
        foreach ($k in $t.Keys) { $o[$k] = $t[$k] }
        $id = [string](Get-JField $t 'id')
        $o['backlog'] = if ($backlogById.ContainsKey($id)) { $backlogById[$id] } else { $null }
        [void]$tasksOut.Add($o)
    }

    $reportsOut = Get-JArray
    foreach ($r in $scoutReports) {
        $o = Get-JObject
        foreach ($k in $r.Keys) { $o[$k] = $r[$k] }
        $id = [string](Get-JField $r 'id')
        $kind = $null
        if ($taskById.ContainsKey($id)) { $kind = Get-JField $taskById[$id] 'kind' }
        if ($null -eq $kind -and $backlogById.ContainsKey($id)) { $kind = Get-JField $backlogById[$id] 'kind' }
        if ($null -eq $kind) { $kind = 'scout' }
        $o['kind'] = $kind
        [void]$reportsOut.Add($o)
    }

    $roots = Get-JObject
    $roots['fm_root'] = $fmRoot
    $roots['state'] = $stateDir
    $roots['data'] = $dataDir
    $roots['config'] = $configDir
    $roots['projects'] = $projectsDir

    $guidance = Get-JObject
    $guidance['note'] = 'For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority.'

    $snapshot = Get-JObject
    $snapshot['schema'] = 'fm-fleet-snapshot.v1'
    $snapshot['generated'] = $snapshotNow
    $snapshot['fm_home'] = $fmHome
    $snapshot['roots'] = $roots
    $snapshot['backlog'] = $backlogJson
    $snapshot['tasks'] = $tasksOut
    $snapshot['main_inventory'] = $mainInventory
    $snapshot['scout_reports'] = $reportsOut
    $snapshot['secondmate_current'] = $secondmateCurrent
    $snapshot['secondmate_landed'] = $secondmateLanded
    $snapshot['secondmate_guidance'] = $guidance

    Write-FmOut (ConvertTo-JqJson $snapshot)
    Exit-FmScript 0
}
