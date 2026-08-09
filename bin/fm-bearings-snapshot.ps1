# fm-bearings-snapshot.ps1 - compact, bounded, TOON-by-default bearings projection.
#
# Twin: bin/fm-bearings-snapshot.sh
#
# A thin wrapper OVER the canonical bin/fm-fleet-snapshot. It does not parse
# fleet state itself: it shells out to `fm-fleet-snapshot --json`, projects that
# complete structured contract down to the small set of fields a "pick up where I
# left off" read needs, and renders TOON at the output boundary. The internal data
# model stays JSON (`--json` prints it verbatim); TOON is the default agent-facing
# format per the AXI standard, and TOON/JSON are parity representations of the same
# projected model. The projection is view-specific: it DROPS fields from the bearings
# output, it never removes them from - or otherwise weakens - the canonical snapshot,
# which stays complete.
#
# LOCAL-ONLY by default: a normal invocation makes ZERO GitHub/network/auth calls.
# It MAY surface PR URLs already recorded locally in task meta (recorded_prs), but it
# performs no live discovery or checks. Live PR discovery/checks happen ONLY under
# --include-prs, which is the sole path that touches the network; all gh coupling
# lives in that branch and never in the canonical snapshot. The default output states
# explicitly (the prs: line and the omitted[] surfaces) what was not requested, so an
# absence is never ambiguous.
#
# This wrapper consumes canonical status decisions plus canonically normalized
# backlog roles, unresolved blockers, and captain actionability. It never infers
# decisions from report or visual-review prose or reimplements snapshot semantics.
#
# Flags:
#   (default)        compact projection, TOON, local-only
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --include-prs    ALSO do live open-PR discovery + checks (the only network path)
#   --fields <list>  opt in to dropped surfaces: bodies,paths,actions,endpoints
#   --all-in-flight  include every in-flight task
#   --all-decisions  include every open decision
#   --all-secondmates include every aggregated secondmate record
#   --all-landed     include every landed record from every home (default: bounded)
#   --all-reports    include the full scout-report inventory (default: relevant only)
#   --all-queued     include superseded queued items (default: dropped)
#   --all-recorded-prs include every locally recorded PR
#   --all-unhealthy  include every unhealthy endpoint
#   --all-pr-repos   query every discovered repository under --include-prs
#   -h,--help        usage
#
# Output contract: `fm-bearings.v1`. Read-only; no locks, no mutation, no reports.
#
# ---------------------------------------------------------------------------
# THE JQ PROGRAM BECAME POWERSHELL, SO FOUR JQ SEMANTICS ARE REPRODUCED BY HAND
#
# The bash twin's projection is one ~200-line jq program, and jq's evaluation
# rules are not PowerShell's. Four of them decide whether the two twins agree:
#
#   1. `//` IS NULL-OR-FALSE, NOT EMPTY. `.reason // "-"` keeps an EMPTY STRING;
#      only null and false fall through. Get-JqAlt below is that operator, and
#      using PowerShell's own falsiness here would silently replace legitimate
#      empty values with placeholders.
#   2. `"x" + null` IS "x". jq's + treats null as the identity, which is why the
#      decision summaries concatenate a possibly-null hold reason without a
#      guard. Get-JqStr maps null to the empty string for exactly that reason.
#   3. SORTING AND SLICING ARE BY CODEPOINT. jq compares strings by codepoint and
#      slices strings by codepoint; .NET's default string comparison is
#      culture-aware and its indexer is UTF-16 code units. Every sort below uses
#      StringComparer::Ordinal and every truncation counts codepoints, so a
#      hyphenated id or an emoji in a title cannot reorder or split differently
#      between the two twins.
#   4. MISSING IS NULL, NOT AN ERROR. jq yields null for an absent key; under
#      Set-StrictMode the same access throws. Get-JqNode/Get-JqList are the safe
#      readers, and nothing below indexes a parsed node directly.
#
# The JSON writer is hand-rolled for the same reason: `--json` prints the model
# in jq's pretty form (two-space indent, `[]`/`{}` for empties), and
# ConvertTo-Json matches neither the indentation nor the separators, so a
# machine consumer reading either twin would see two different documents.
#
# jq itself is NOT required by this twin, so the bash twin's `command -v jq`
# refusal (exit 1) has no equivalent here. That is the only exit code the two do
# not share.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $ord = [System.StringComparison]::Ordinal
    $ellipsis = [string][char]0x2026

    function Write-Bearings([string]$Message) {
        Write-FmErr "fm-bearings-snapshot: $Message"
    }

    # --- jq value helpers -----------------------------------------------------
    function Get-JqNode($Node, [string]$Key) {
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Key)) { return $Node[$Key] }
        }
        return $null
    }
    function Get-JqPath($Node, [string[]]$Keys) {
        foreach ($key in $Keys) { $Node = Get-JqNode $Node $key }
        return $Node
    }
    function Get-JqList($Node, [string]$Key) {
        $value = Get-JqNode $Node $Key
        if ($null -eq $value) { return @() }
        return @($value)
    }
    # `a // b`: null and false fall through, an empty string does NOT.
    function Get-JqAlt($Primary, $Fallback) {
        if ($null -eq $Primary) { return $Fallback }
        if (($Primary -is [bool]) -and (-not $Primary)) { return $Fallback }
        return $Primary
    }
    # `"x" + null` is "x".
    function Get-JqStr($Value) {
        if ($null -eq $Value) { return '' }
        if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
        return [string]$Value
    }

    function Get-CodepointLength([string]$Text) {
        $count = 0
        for ($i = 0; $i -lt $Text.Length; $i++) {
            if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and
                [char]::IsLowSurrogate($Text[$i + 1])) { $i++ }
            $count++
        }
        return $count
    }
    function Get-CodepointPrefix([string]$Text, [int]$Max) {
        if ($Max -le 0) { return '' }
        $count = 0
        $i = 0
        while ($i -lt $Text.Length -and $count -lt $Max) {
            $width = 1
            if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and
                [char]::IsLowSurrogate($Text[$i + 1])) { $width = 2 }
            $i += $width
            $count++
        }
        return $Text.Substring(0, $i)
    }
    # `def trunc($n)`: null stays null; whitespace runs collapse to one space;
    # an over-long value is cut by CODEPOINT and marked with the ellipsis.
    function Get-JqTrunc($Value, [int]$Max) {
        if ($null -eq $Value) { return $null }
        $text = Get-JqStr $Value
        $text = [regex]::Replace($text, "[ \t\n\r\f\v]+", ' ')
        if ((Get-CodepointLength $text) -gt $Max) {
            return (Get-CodepointPrefix $text $Max) + $ellipsis
        }
        return $text
    }

    function Compare-JqKey([string[]]$Left, [string[]]$Right) {
        for ($i = 0; $i -lt $Left.Count -and $i -lt $Right.Count; $i++) {
            $cmp = [string]::CompareOrdinal($Left[$i], $Right[$i])
            if ($cmp -ne 0) { return $cmp }
        }
        return 0
    }
    # jq's sort_by is stable; the recorded position breaks every tie so the
    # reverse that follows sees exactly jq's ordering.
    function Sort-JqRecord($Rows, [scriptblock]$KeySelector) {
        $indexed = @()
        $position = 0
        foreach ($row in $Rows) {
            $indexed += , [pscustomobject]@{ Row = $row; Key = (& $KeySelector $row); Pos = $position }
            $position++
        }
        $sorted = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $indexed) { $sorted.Add($item) }
        # Cast explicitly: List<T>.Sort is overloaded on IComparer<T> and
        # Comparison<T>, and a bare scriptblock cannot pick between them.
        $comparison = [System.Comparison[object]] {
            param($a, $b)
            $cmp = Compare-JqKey $a.Key $b.Key
            if ($cmp -ne 0) { return $cmp }
            return $a.Pos.CompareTo($b.Pos)
        }
        $sorted.Sort($comparison)
        return @($sorted | ForEach-Object { $_.Row })
    }

    # --- jq-compatible writers -----------------------------------------------
    function ConvertTo-JqJsonString([string]$Text) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        foreach ($ch in $Text.ToCharArray()) {
            switch ([int]$ch) {
                0x22 { [void]$sb.Append('\"') }
                0x5C { [void]$sb.Append('\\') }
                0x08 { [void]$sb.Append('\b') }
                0x0C { [void]$sb.Append('\f') }
                0x0A { [void]$sb.Append('\n') }
                0x0D { [void]$sb.Append('\r') }
                0x09 { [void]$sb.Append('\t') }
                default {
                    if ([int]$ch -lt 0x20) { [void]$sb.Append('\u{0:x4}' -f [int]$ch) }
                    else { [void]$sb.Append($ch) }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    function ConvertTo-JqNumber($Value) {
        if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
            return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return ([long]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    function Test-JqNumber($Value) {
        return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
            $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or $Value -is [uint32])
    }
    # jq's pretty form: two-space indent, `[]`/`{}` for empties, no space before
    # the colon.
    function ConvertTo-JqPretty($Value, [int]$Depth) {
        $pad = ' ' * (2 * $Depth)
        $inner = ' ' * (2 * ($Depth + 1))
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
        if (Test-JqNumber $Value) { return (ConvertTo-JqNumber $Value) }
        if ($Value -is [string]) { return (ConvertTo-JqJsonString $Value) }
        if ($Value -is [System.Collections.IDictionary]) {
            $keys = @($Value.Keys)
            if ($keys.Count -eq 0) { return '{}' }
            $parts = @()
            foreach ($key in $keys) {
                $parts += ($inner + (ConvertTo-JqJsonString ([string]$key)) + ': ' +
                    (ConvertTo-JqPretty $Value[$key] ($Depth + 1)))
            }
            return "{`n" + ($parts -join ",`n") + "`n$pad}"
        }
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($item in $items) { $parts += ($inner + (ConvertTo-JqPretty $item ($Depth + 1))) }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }

    # --- TOON renderer (output boundary; parity with the JSON model) ----------
    # The model is a flat object of scalar fields plus arrays of uniform scalar
    # objects, so the encoder only needs object scalars, the tabular array form
    # and the empty-array form, per the TOON spec. Quoting follows the spec.
    function ConvertTo-ToonQuoted($Value) {
        $text = Get-JqStr $Value
        $needsQuote = ($text -eq '') -or
            ([regex]::IsMatch($text, "^[ \t\n\r\f\v]|[ \t\n\r\f\v]$")) -or
            ($text -ceq 'true' -or $text -ceq 'false' -or $text -ceq 'null') -or
            ([regex]::IsMatch($text, '^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$')) -or
            ([regex]::IsMatch($text, '[:"\\\[\]{},]')) -or
            ([regex]::IsMatch($text, '[\x00-\x1F\x7F]')) -or
            ($text.StartsWith('-', $ord))
        if (-not $needsQuote) { return $text }
        $escaped = $text.Replace('\', '\\').Replace('"', '\"').
            Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
        return '"' + $escaped + '"'
    }
    function ConvertTo-ToonScalar($Value) {
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
        if (Test-JqNumber $Value) { return (ConvertTo-JqNumber $Value) }
        return (ConvertTo-ToonQuoted $Value)
    }
    function ConvertTo-Toon($Model) {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($key in @($Model.Keys)) {
            $value = $Model[$key]
            $isArray = ($null -ne $value) -and ($value -isnot [string]) -and
                ($value -isnot [System.Collections.IDictionary]) -and
                (($value -is [array]) -or ($value -is [System.Collections.IList]))
            if (-not $isArray) {
                $lines.Add("${key}: " + (ConvertTo-ToonScalar $value))
                continue
            }
            $rows = @($value)
            if ($rows.Count -eq 0) { $lines.Add("${key}: []"); continue }
            $fields = @($rows[0].Keys)
            $header = @($fields | ForEach-Object { ConvertTo-ToonQuoted $_ })
            $lines.Add("$key[$($rows.Count)]{$($header -join ',')}:")
            foreach ($row in $rows) {
                $cells = @()
                foreach ($field in $fields) {
                    $cell = $null
                    if ($row -is [System.Collections.IDictionary] -and $row.Contains($field)) {
                        $cell = $row[$field]
                    }
                    $cells += (ConvertTo-ToonScalar $cell)
                }
                $lines.Add('  ' + ($cells -join ','))
            }
        }
        return ($lines -join "`n")
    }

    # --- bounds ---------------------------------------------------------------
    function Get-Bound([string]$Name, [string]$Fallback) {
        $value = Get-FmEnv $Name $Fallback
        if ($value -notmatch '^[0-9]+$' -or [long]$value -eq 0) {
            Write-Bearings "$Name must be a positive integer"
            Exit-FmScript 2
        }
        return [long]$value
    }
    $landedN = Get-Bound 'FM_BEARINGS_LANDED' '6'
    $landedPerHomeN = Get-Bound 'FM_BEARINGS_LANDED_PER_HOME' ([string]$landedN)
    $inFlightN = Get-Bound 'FM_BEARINGS_IN_FLIGHT' '20'
    $decisionsN = Get-Bound 'FM_BEARINGS_DECISIONS' '20'
    $secondmatesN = Get-Bound 'FM_BEARINGS_SECONDMATES' '20'
    $gatesN = Get-Bound 'FM_BEARINGS_GATES' '20'
    $reportsN = Get-Bound 'FM_BEARINGS_REPORTS' '20'
    $recordedPrsN = Get-Bound 'FM_BEARINGS_RECORDED_PRS' '20'
    $unhealthyN = Get-Bound 'FM_BEARINGS_UNHEALTHY' '20'
    $prReposN = Get-Bound 'FM_BEARINGS_PR_REPOS' '10'
    $prLimit = Get-Bound 'FM_BEARINGS_PR_LIMIT' '20'
    # An invalid timeout is silently reset, not refused - the bash twin's `case`
    # rewrites it before validate_bound ever sees it.
    $prTimeout = Get-FmEnv 'FM_BEARINGS_PR_TIMEOUT' '20'
    if ($prTimeout -notmatch '^[0-9]+$' -or [long]$prTimeout -eq 0) { $prTimeout = '20' }

    function Write-BearingsUsage([switch]$ToError) {
        $text = @(
            'usage: fm-bearings-snapshot.ps1 [--json] [--include-prs] [--fields <list>]'
            '                               [--all-in-flight] [--all-decisions]'
            '                               [--all-secondmates] [--all-landed]'
            '                               [--all-reports] [--all-queued]'
            '                               [--all-recorded-prs] [--all-unhealthy]'
            '                               [--all-pr-repos]'
            ''
            'Compact bearings projection over fm-fleet-snapshot. TOON by default.'
            'Default is LOCAL-ONLY (no network); --include-prs is the only path that fetches.'
            ''
            'Default fields: schema, home, generated, prs, in_flight{id,kind,state,doing},'
            '  secondmates{id,state,doing,provenance,freshness,age_seconds,contradiction,reason},'
            '  decisions_open{id,key,verb,summary,owner}, landed{id,what,artifact,owner},'
            '  gates{id,title,blocked_by,reason,owner}, reports{id,path}, recorded_prs{id,url},'
            '  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.'
            'landed merges this home''s Done with registered secondmate homes'' Done, bounded by'
            '  a per-home cap (FM_BEARINGS_LANDED_PER_HOME) and an overall cap (FM_BEARINGS_LANDED),'
            '  with omitted[] disclosure. Default selection is balanced across deterministic home'
            '  order while preserving each home''s internal newest-first order; sparse homes do'
            '  not waste capacity. --all-landed reveals the full global newest-first set.'
            'For every registered secondmate, readable structured facts from its own home are'
            '  authoritative, including independently trustworthy surfaces from a partial summary.'
            '  Parent events and bounded terminal reads are labeled fallback or contradiction'
            '  evidence and never become current work.'
            'Opt-in surfaces: --fields bodies|paths|actions|endpoints, --all-in-flight,'
            '  --all-decisions, --all-secondmates, --all-landed, --all-reports, --all-queued, --all-recorded-prs,'
            '  --all-unhealthy, --all-pr-repos, --include-prs (adds candidate_prs).'
            'Raise FM_BEARINGS_PR_LIMIT to expand per-repository open-PR results.'
        )
        foreach ($line in $text) {
            if ($ToError) { Write-FmErr $line } else { Write-FmOut $line }
        }
    }

    # --- argv -----------------------------------------------------------------
    $format = 'toon'
    $includePrs = $false
    $allReports = $false
    $allQueued = $false
    $allInFlight = $false
    $allDecisions = $false
    $allSecondmates = $false
    $allLanded = $false
    $allRecordedPrs = $false
    $allUnhealthy = $false
    $allPrRepos = $false
    $fields = ''
    $i = 0
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        switch -CaseSensitive ($arg) {
            '--json' { $format = 'json' }
            '--include-prs' { $includePrs = $true }
            '--all-reports' { $allReports = $true }
            '--all-queued' { $allQueued = $true }
            '--all-in-flight' { $allInFlight = $true }
            '--all-decisions' { $allDecisions = $true }
            '--all-secondmates' { $allSecondmates = $true }
            '--all-landed' { $allLanded = $true }
            '--all-recorded-prs' { $allRecordedPrs = $true }
            '--all-unhealthy' { $allUnhealthy = $true }
            '--all-pr-repos' { $allPrRepos = $true }
            '--fields' {
                $fields = if (($i + 1) -lt $fmArgv.Count) { [string]$fmArgv[$i + 1] } else { '' }
                $i++
            }
            '-h' { Write-BearingsUsage; Exit-FmScript 0 }
            '--help' { Write-BearingsUsage; Exit-FmScript 0 }
            default {
                if ($arg.StartsWith('--fields=', $ord)) { $fields = $arg.Substring(9) }
                else { Write-BearingsUsage -ToError; Exit-FmScript 2 }
            }
        }
        $i++
    }

    # The deterministic return-catch-up owner must clear before this or any other
    # ordinary captain request proceeds. Bearings does not reproduce that policy;
    # it only consults the shared read-only gate.
    $guard = Invoke-FmScript 'fm-afk-return' @('guard') -Stream
    if ($guard.ExitCode -ne 0) { Exit-FmScript $guard.ExitCode }

    $now = Get-FmEnv 'FM_BEARINGS_NOW'
    if ([string]::IsNullOrEmpty($now)) { $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

    # The snapshot's own environment knobs are passed the only way a child can
    # receive them: through this process's environment, restored afterwards so a
    # later call in the same process is unaffected.
    $savedNow = [Environment]::GetEnvironmentVariable('FM_SNAPSHOT_NOW')
    $savedMates = [Environment]::GetEnvironmentVariable('FM_SNAPSHOT_SECONDMATES')
    $savedPerHome = [Environment]::GetEnvironmentVariable('FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME')
    $snapResult = $null
    try {
        [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_NOW', $now)
        if ($allLanded -or $allSecondmates) {
            [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_SECONDMATES', '0')
            if ($allLanded) {
                [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME', '0')
            }
        }
        $snapResult = Invoke-FmScript 'fm-fleet-snapshot' @('--json')
    } finally {
        [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_NOW', $savedNow)
        [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_SECONDMATES', $savedMates)
        [Environment]::SetEnvironmentVariable('FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME', $savedPerHome)
    }
    if (-not [string]::IsNullOrEmpty($snapResult.StdErr)) { [Console]::Error.Write($snapResult.StdErr) }
    if ($snapResult.ExitCode -ne 0) { Exit-FmScript $snapResult.ExitCode }

    $snap = $null
    try { $snap = $snapResult.StdOut | ConvertFrom-Json -AsHashtable } catch { $snap = $null }
    $fmHomeValue = Get-JqNode $snap 'fm_home'
    if ($null -eq $snap -or $fmHomeValue -isnot [string]) {
        Write-Bearings 'invalid canonical snapshot'
        Exit-FmScript 1
    }
    # `.fm_home | split("/") | (.[-2:] | join("/"))`: the last two path segments,
    # or the whole thing when there are fewer than two.
    $segments = @($fmHomeValue.Split('/'))
    $tail = if ($segments.Count -ge 2) { $segments[-2..-1] } else { $segments }
    $homeLabel = ($tail -join '/')

    $tasks = Get-JqList $snap 'tasks'
    $backlogRecords = Get-JqList (Get-JqNode $snap 'backlog') 'records'
    $secondmateCurrent = Get-JqNode $snap 'secondmate_current'
    $secondmateRecords = Get-JqList $secondmateCurrent 'records'
    $secondmateLanded = Get-JqNode $snap 'secondmate_landed'
    $mainInventory = Get-JqNode $snap 'main_inventory'

    # --- optional live PR enrichment (the ONLY network path) ------------------
    $prStatus = 'not_requested (run: /bearings include PRs)'
    $candidatePrs = @()
    $prReposTotal = 0
    $prReposShown = 0
    $prRowsCapped = 0
    $prRowsMinTotal = 0

    # Parse owner/repo from an https or ssh GitHub remote/PR URL; empty if not.
    function Get-RepoSlug([string]$Url) {
        $match = [regex]::Match($Url, 'github\.com[:/]([^/]*/[^/]*)')
        if (-not $match.Success) { return '' }
        $slug = $match.Groups[1].Value
        $slug = $slug -replace '\.git$', ''
        $slug = $slug -replace '/pull/.*$', ''
        $slug = $slug -replace '/$', ''
        return $slug
    }

    if ($includePrs) {
        if (-not (Test-FmCommand 'gh')) {
            $prStatus = 'unavailable (gh not found)'
        } else {
            $repos = [System.Collections.Generic.List[string]]::new()
            function Add-Repo([string]$Slug) {
                if ([string]::IsNullOrEmpty($Slug)) { return }
                if (-not $repos.Contains($Slug)) { $repos.Add($Slug) }
            }
            foreach ($task in $tasks) {
                $url = Get-JqPath $task @('pr', 'url')
                if ($url -is [string] -and $url -ne '') { Add-Repo (Get-RepoSlug $url) }
            }
            foreach ($task in $tasks) {
                if ((Get-JqStr (Get-JqNode $task 'kind')) -eq 'secondmate') { continue }
                $worktree = Get-JqPath $task @('paths', 'worktree', 'path')
                if ($worktree -isnot [string] -or $worktree -eq '') { continue }
                $nativeWorktree = ConvertTo-FmNativePath $worktree
                if (-not [System.IO.Directory]::Exists($nativeWorktree)) { continue }
                # `git ... || continue`: a missing or failing git skips the
                # worktree. .NET raises for a missing program, so it is caught
                # back into the same skip.
                $remote = $null
                try {
                    $remote = Invoke-FmTool -FilePath 'git' `
                        -Arguments @('-C', $nativeWorktree, 'remote', 'get-url', 'origin')
                } catch { continue }
                if (-not $remote.Ok) { continue }
                Add-Repo (Get-RepoSlug $remote.StdOut.Trim())
            }
            $prReposTotal = $repos.Count

            $nrepos = 0; $npr = 0; $nwarn = 0; $ncapped = 0
            $rows = [System.Collections.Generic.List[object]]::new()
            $savedPrompt = [Environment]::GetEnvironmentVariable('GH_PROMPT_DISABLED')
            $savedNotifier = [Environment]::GetEnvironmentVariable('GH_NO_UPDATE_NOTIFIER')
            try {
                [Environment]::SetEnvironmentVariable('GH_PROMPT_DISABLED', '1')
                [Environment]::SetEnvironmentVariable('GH_NO_UPDATE_NOTIFIER', '1')
                foreach ($repo in $repos) {
                    if (-not $allPrRepos -and $nrepos -ge $prReposN) { break }
                    $nrepos++
                    $gh = Invoke-FmTool -FilePath 'gh' -TimeoutSeconds ([int]$prTimeout) -Arguments @(
                        'pr', 'list', '--repo', $repo, '--state', 'open',
                        '--limit', [string]($prLimit + 1),
                        '--json', 'number,title,url,headRefName,reviewDecision,mergeable,statusCheckRollup')
                    if (-not $gh.Ok) { $nwarn++; continue }
                    $parsed = $null
                    try {
                        $text = if ([string]::IsNullOrWhiteSpace($gh.StdOut)) { '[]' } else { $gh.StdOut }
                        $parsed = @($text | ConvertFrom-Json -AsHashtable)
                    } catch { $nwarn++; continue }
                    $repoRows = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in $parsed) {
                        $head = Get-JqStr (Get-JqNode $item 'headRefName')
                        $checks = 'none'
                        $rollup = Get-JqList $item 'statusCheckRollup'
                        if ($rollup.Count -gt 0) {
                            $failing = $false
                            $pending = $false
                            foreach ($check in $rollup) {
                                $s = Get-JqStr (Get-JqAlt (Get-JqNode $check 'conclusion') (Get-JqNode $check 'state'))
                                if ($s -in @('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED')) {
                                    $failing = $true
                                }
                                if ((Get-JqStr (Get-JqNode $check 'status')) -ne 'COMPLETED' -and
                                    (Get-JqStr (Get-JqNode $check 'state')) -ne 'SUCCESS') { $pending = $true }
                            }
                            $checks = if ($failing) { 'failing' } elseif ($pending) { 'pending' } else { 'passing' }
                        }
                        $repoRows.Add([ordered]@{
                                num       = Get-JqStr (Get-JqNode $item 'number')
                                repo      = $repo
                                task      = if ($head.StartsWith('fm/', $ord)) { $head.Substring(3) } else { '-' }
                                url       = Get-JqStr (Get-JqAlt (Get-JqNode $item 'url') '-')
                                review    = Get-JqStr (Get-JqAlt (Get-JqNode $item 'reviewDecision') 'none')
                                mergeable = Get-JqStr (Get-JqAlt (Get-JqNode $item 'mergeable') 'UNKNOWN')
                                checks    = $checks
                            })
                    }
                    $repoRowArray = @($repoRows)
                    $returned = $repoRowArray.Count
                    $kept = @(if ($returned -gt $prLimit) { $repoRowArray[0..($prLimit - 1)] } else { $repoRowArray })
                    if ($returned -gt $prLimit) { $ncapped++ }
                    $npr += $kept.Count
                    foreach ($row in $kept) { $rows.Add($row) }
                }
            } finally {
                [Environment]::SetEnvironmentVariable('GH_PROMPT_DISABLED', $savedPrompt)
                [Environment]::SetEnvironmentVariable('GH_NO_UPDATE_NOTIFIER', $savedNotifier)
            }
            $prReposShown = $nrepos
            $prRowsCapped = $ncapped
            $prRowsMinTotal = $npr + $ncapped
            $candidatePrs = @($rows)
            $warnnote = if ($nwarn -gt 0) { "; $nwarn repo(s) unavailable" } else { '' }
            if ($ncapped -gt 0) {
                $prStatus = "checked ($nrepos repos; $npr shown, at least $prRowsMinTotal open; capped in $ncapped repo(s)$warnnote)"
            } else {
                $prStatus = "checked ($nrepos repos, $npr open$warnnote)"
            }
        }
    }

    # --- projection: canonical snapshot -> fm-bearings.v1 model ---------------
    $fieldList = @($fields.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $fBodies = $fieldList -ccontains 'bodies'
    $fPaths = $fieldList -ccontains 'paths'
    $fActions = $fieldList -ccontains 'actions'
    $fEndpoints = $fieldList -ccontains 'endpoints'

    $mainDone = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $backlogRecords) {
        if ((Get-JqStr (Get-JqNode $record 'state')) -ne 'done') { continue }
        if ($true -ne (Get-JqNode $record 'structured')) { continue }
        if ((Get-JqStr (Get-JqNode $record 'kind')) -eq 'captain') { continue }
        $mainDone.Add([ordered]@{
                id          = Get-JqNode $record 'id'
                title       = Get-JqNode $record 'title'
                pr_url      = Get-JqNode $record 'pr_url'
                report_path = Get-JqNode $record 'report_path'
                local_note  = Get-JqNode $record 'local_note'
                completion  = Get-JqNode $record 'completion'
                home        = '(main)'
                home_id     = '(main)'
            })
    }
    $allLandedRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $mainDone) { $allLandedRows.Add($row) }
    foreach ($row in (Get-JqList $secondmateLanded 'records')) { $allLandedRows.Add($row) }

    # group_by(.home_id): jq sorts by the key, so the groups arrive in codepoint
    # order of home_id and each group keeps its input order.
    $groupOrder = [System.Collections.Generic.List[string]]::new()
    $groups = @{}
    foreach ($row in $allLandedRows) {
        $homeId = Get-JqStr (Get-JqNode $row 'home_id')
        if (-not $groups.ContainsKey($homeId)) {
            $groups[$homeId] = [System.Collections.Generic.List[object]]::new()
            $groupOrder.Add($homeId)
        }
        $groups[$homeId].Add($row)
    }
    $groupOrder.Sort([System.StringComparer]::Ordinal)

    $landedKey = {
        param($row)
        @((Get-JqStr (Get-JqAlt (Get-JqPath $row @('completion', 'date')) '')), (Get-JqStr (Get-JqNode $row 'id')))
    }
    $perHomeGroups = @()
    $homeCapDropped = 0
    foreach ($homeId in $groupOrder) {
        $sortedGroup = @(Sort-JqRecord $groups[$homeId] $landedKey)
        [array]::Reverse($sortedGroup)
        if ($groups[$homeId].Count -gt $landedPerHomeN) { $homeCapDropped++ }
        if (-not $allLanded -and $sortedGroup.Count -gt $landedPerHomeN) {
            $sortedGroup = @($sortedGroup[0..($landedPerHomeN - 1)])
        }
        $perHomeGroups += , $sortedGroup
    }
    $perHomeCapped = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $perHomeGroups) { foreach ($row in $group) { $perHomeCapped.Add($row) } }

    if ($allLanded) {
        $done = @(Sort-JqRecord $perHomeCapped $landedKey)
        [array]::Reverse($done)
    } else {
        # round_robin_landed: one row from each home in turn, so a sparse home
        # never wastes capacity and no home starves.
        $maxLen = 0
        foreach ($group in $perHomeGroups) { if ($group.Count -gt $maxLen) { $maxLen = $group.Count } }
        $roundRobin = [System.Collections.Generic.List[object]]::new()
        for ($slot = 0; $slot -lt $maxLen; $slot++) {
            foreach ($group in $perHomeGroups) {
                if ($group.Count -gt $slot) { $roundRobin.Add($group[$slot]) }
            }
        }
        $roundRobinArray = @($roundRobin)
        $done = @(if ($roundRobinArray.Count -gt $landedN) { $roundRobinArray[0..($landedN - 1)] } else { $roundRobinArray })
    }

    $doneIds = @($done | ForEach-Object { Get-JqStr (Get-JqNode $_ 'id') })
    $liveIds = @()
    $workingIds = @()
    foreach ($task in $tasks) {
        if ((Get-JqStr (Get-JqNode $task 'kind')) -eq 'secondmate') { continue }
        $liveIds += Get-JqStr (Get-JqNode $task 'id')
        if ((Get-JqStr (Get-JqPath $task @('current_state', 'state'))) -eq 'working') {
            $workingIds += Get-JqStr (Get-JqNode $task 'id')
        }
    }
    $relIds = @($liveIds) + @($doneIds)

    $unhealthyAll = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        $endpoint = Get-JqNode $task 'endpoint'
        $exists = Get-JqNode $endpoint 'exists'
        $agent = Get-JqStr (Get-JqNode $endpoint 'agent_alive')
        if ($exists -ne $false -and $agent -ne 'dead') { continue }
        $unhealthyAll.Add([ordered]@{
                id      = Get-JqNode $task 'id'
                backend = Get-JqNode $task 'backend'
                target  = Get-JqAlt (Get-JqNode $endpoint 'target') '-'
                exists  = $exists
                agent   = Get-JqNode $endpoint 'agent_alive'
            })
    }
    foreach ($mate in $secondmateRecords) {
        foreach ($entry in (Get-JqList $mate 'endpoints')) {
            $endpoint = Get-JqNode $entry 'endpoint'
            $exists = Get-JqNode $endpoint 'exists'
            $agent = Get-JqStr (Get-JqNode $endpoint 'agent_alive')
            if ($exists -ne $false -and $agent -ne 'dead') { continue }
            $unhealthyAll.Add([ordered]@{
                    id      = (Get-JqStr (Get-JqNode $mate 'id')) + '/' + (Get-JqStr (Get-JqNode $entry 'id'))
                    backend = 'secondmate-home'
                    target  = Get-JqAlt (Get-JqNode $endpoint 'target') '-'
                    exists  = $exists
                    agent   = Get-JqNode $endpoint 'agent_alive'
                })
        }
    }

    # A secondmate's own home state is authoritative; a parent-side captain
    # decision is only reported when a captain hold actually backs it.
    $secondmateViews = [System.Collections.Generic.List[object]]::new()
    foreach ($mate in $secondmateRecords) {
        $captainHolds = @(Get-JqList $mate 'decisions_open' | Where-Object {
                (Get-JqStr (Get-JqNode $_ 'source')) -eq 'backlog' -and
                (Get-JqStr (Get-JqNode $_ 'verb')) -eq 'captain-hold'
            })
        $backlogHolds = @(Get-JqList $mate 'holds' | Where-Object {
                (Get-JqStr (Get-JqNode $_ 'source')) -eq 'backlog'
            })
        $currentState = Get-JqStr (Get-JqPath $mate @('current', 'state'))
        $activeChildren = Get-JqList $mate 'active_children'
        $bearingsHolds = if ($currentState -eq 'captain_decision') { $backlogHolds } else { Get-JqNode $mate 'holds' }
        $bearingsState = $currentState
        if ($currentState -eq 'captain_decision') {
            $bearingsState =
                if ($captainHolds.Count -gt 0) { 'captain_decision' }
                elseif ($activeChildren.Count -gt 0) { 'active_child_work' }
                elseif ($backlogHolds.Count -gt 0) { 'externally_held' }
                else { 'unknown' }
        }
        $secondmateViews.Add([ordered]@{
                Record        = $mate
                CaptainHolds  = $captainHolds
                Holds         = $bearingsHolds
                State         = $bearingsState
                ActiveChildren = $activeChildren
            })
    }

    $secondmatesAll = [System.Collections.Generic.List[object]]::new()
    $registry = Get-JqNode $secondmateCurrent 'registry'
    if ($false -eq (Get-JqNode $registry 'available')) {
        $reason = Get-JqStr (Get-JqAlt (Get-JqNode $registry 'reason') 'Registered secondmate table unavailable')
        $secondmatesAll.Add([ordered]@{
                id            = '(registry)'
                state         = 'unknown'
                doing         = $reason
                provenance    = Get-JqStr (Get-JqAlt (Get-JqNode $registry 'provenance') 'registered-table')
                freshness     = Get-JqStr (Get-JqAlt (Get-JqPath $registry @('freshness', 'status')) 'unavailable')
                age_seconds   = $null
                contradiction = $false
                reason        = $reason
            })
    }
    foreach ($view in $secondmateViews) {
        $mate = $view.Record
        $doing = switch ($view.State) {
            'active_child_work' {
                (@($view.ActiveChildren | ForEach-Object {
                            (Get-JqStr (Get-JqNode $_ 'id')) + ': ' +
                            (Get-JqStr (Get-JqAlt (Get-JqNode $_ 'doing') (Get-JqNode $_ 'state')))
                        }) -join '; ')
            }
            'captain_decision' {
                (@($view.CaptainHolds | ForEach-Object { Get-JqStr (Get-JqNode $_ 'summary') }) -join '; ')
            }
            'externally_held' {
                (@(@($view.Holds) | ForEach-Object {
                            (Get-JqStr (Get-JqNode $_ 'id')) + ': ' +
                            (Get-JqStr (Get-JqAlt (Get-JqNode $_ 'reason') 'held'))
                        }) -join '; ')
            }
            'no_active_work' { 'No active child work' }
            default { Get-JqStr (Get-JqAlt (Get-JqPath $mate @('current', 'reason')) 'Current home state unavailable') }
        }
        $secondmatesAll.Add([ordered]@{
                id            = Get-JqNode $mate 'id'
                state         = $view.State
                doing         = Get-JqTrunc $doing 120
                provenance    = Get-JqPath $mate @('provenance', 'selected')
                freshness     = Get-JqPath $mate @('freshness', 'status')
                age_seconds   = Get-JqPath $mate @('freshness', 'age_seconds')
                contradiction = Get-JqAlt (Get-JqNode $mate 'contradiction') $false
                reason        = Get-JqAlt (Get-JqPath $mate @('current', 'reason')) '-'
            })
    }

    $inFlightAll = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        if ((Get-JqStr (Get-JqNode $task 'kind')) -eq 'secondmate') { continue }
        $role = Get-JqStr (Get-JqPath $task @('backlog', 'current_role'))
        if ($role -eq 'program') { continue }
        $state = Get-JqStr (Get-JqPath $task @('current_state', 'state'))
        if ($role -eq 'held' -and $state -ne 'working') { continue }
        $detail = Get-JqStr (Get-JqAlt (Get-JqPath $task @('current_state', 'detail')) '')
        if ($detail -eq '') { $detail = Get-JqStr (Get-JqAlt (Get-JqPath $task @('hints', 'last_event_text')) '') }
        $inFlightAll.Add([ordered]@{
                id    = Get-JqNode $task 'id'
                kind  = Get-JqNode $task 'kind'
                state = Get-JqPath $task @('current_state', 'state')
                doing = Get-JqTrunc $detail 90
            })
    }
    foreach ($view in $secondmateViews) {
        if ($view.State -ne 'active_child_work') { continue }
        $doing = (@($view.ActiveChildren | ForEach-Object {
                    (Get-JqStr (Get-JqNode $_ 'id')) + ': ' +
                    (Get-JqStr (Get-JqAlt (Get-JqNode $_ 'doing') (Get-JqNode $_ 'state')))
                }) -join '; ')
        $inFlightAll.Add([ordered]@{
                id    = Get-JqNode $view.Record 'id'
                kind  = 'secondmate'
                state = $view.State
                doing = Get-JqTrunc $doing 90
            })
    }

    $decisionsAll = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $backlogRecords) {
        if ($true -ne (Get-JqNode $record 'structured')) { continue }
        if ($true -ne (Get-JqNode $record 'captain_actionable')) { continue }
        $decisionsAll.Add([ordered]@{
                id      = Get-JqNode $record 'id'
                key     = Get-JqNode $record 'id'
                verb    = 'captain-hold'
                summary = Get-JqTrunc ((Get-JqStr (Get-JqNode $record 'title')) + ': ' +
                    (Get-JqStr (Get-JqNode $record 'hold_reason'))) 90
                owner   = '(main)'
            })
    }
    foreach ($mate in $secondmateRecords) {
        foreach ($decision in (Get-JqList $mate 'decisions_open')) {
            if ((Get-JqStr (Get-JqNode $decision 'source')) -ne 'backlog') { continue }
            if ((Get-JqStr (Get-JqNode $decision 'verb')) -ne 'captain-hold') { continue }
            $summary = (Get-JqStr (Get-JqAlt (Get-JqNode $decision 'summary') (Get-JqNode $decision 'id'))) +
                ': ' + (Get-JqStr (Get-JqAlt (Get-JqNode $decision 'reason') 'captain decision pending'))
            $decisionsAll.Add([ordered]@{
                    id      = (Get-JqStr (Get-JqNode $mate 'id')) + '/' + (Get-JqStr (Get-JqNode $decision 'id'))
                    key     = Get-JqNode $decision 'key'
                    verb    = Get-JqNode $decision 'verb'
                    summary = Get-JqTrunc $summary 90
                    owner   = Get-JqNode $mate 'id'
                })
        }
    }

    function Get-BlockedByText($Record) {
        $ids = @(Get-JqAlt (Get-JqNode $Record 'unresolved_blocker_ids') @())
        $joined = if ($ids.Count -gt 0) { ($ids -join ',') } else { '-' }
        return Get-JqTrunc $joined 120
    }

    $gatesAll = [System.Collections.Generic.List[object]]::new()
    if ($false -eq (Get-JqNode $mainInventory 'valid')) {
        $gatesAll.Add([ordered]@{
                id         = '(main-inventory)'
                title      = Get-JqTrunc (Get-JqAlt (Get-JqNode $mainInventory 'reason') 'main inventory invalid') 60
                blocked_by = '-'
                reason     = 'main inventory'
                owner      = '(main)'
            })
    }
    foreach ($record in $backlogRecords) {
        if ($true -ne (Get-JqNode $record 'structured')) { continue }
        $state = Get-JqStr (Get-JqNode $record 'state')
        $recordId = Get-JqStr (Get-JqNode $record 'id')
        $eligible = ($state -eq 'queued') -or
            ($state -eq 'in_flight' -and
             (Get-JqStr (Get-JqNode $record 'current_role')) -eq 'held' -and
             -not ($workingIds -ccontains $recordId))
        if (-not $eligible) { continue }
        if ($true -eq (Get-JqNode $record 'captain_actionable')) { continue }
        if (-not $allQueued) {
            $excerpt = Get-JqStr (Get-JqAlt (Get-JqNode $record 'body_excerpt') '')
            if ([regex]::IsMatch($excerpt, 'SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED',
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { continue }
        }
        $gatesAll.Add([ordered]@{
                id         = Get-JqNode $record 'id'
                title      = Get-JqTrunc (Get-JqNode $record 'title') 60
                blocked_by = Get-BlockedByText $record
                reason     = Get-JqTrunc (Get-JqAlt (Get-JqAlt (Get-JqNode $record 'hold_reason') (Get-JqNode $record 'blocked_reason')) '-') 40
                owner      = '(main)'
            })
    }
    foreach ($mate in $secondmateRecords) {
        if ((Get-JqStr (Get-JqPath $mate @('provenance', 'selected'))) -ne 'structured-home') { continue }
        foreach ($record in (Get-JqList $mate 'queued')) {
            if ($true -eq (Get-JqNode $record 'captain_actionable')) { continue }
            $gatesAll.Add([ordered]@{
                    id         = Get-JqNode $record 'id'
                    title      = Get-JqTrunc (Get-JqNode $record 'title') 60
                    blocked_by = Get-BlockedByText $record
                    reason     = Get-JqTrunc (Get-JqAlt (Get-JqAlt (Get-JqNode $record 'hold_reason') (Get-JqNode $record 'blocked_reason')) '-') 40
                    owner      = Get-JqNode $mate 'id'
                })
        }
    }

    $reportsAll = [System.Collections.Generic.List[object]]::new()
    foreach ($report in (Get-JqList $snap 'scout_reports')) {
        $reportId = Get-JqStr (Get-JqNode $report 'id')
        if (-not $allReports -and -not ($relIds -ccontains $reportId)) { continue }
        $reportsAll.Add([ordered]@{ id = Get-JqNode $report 'id'; path = Get-JqNode $report 'path' })
    }

    $recordedPrsAll = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        if ((Get-JqStr (Get-JqNode $task 'kind')) -eq 'secondmate') { continue }
        $url = Get-JqPath $task @('pr', 'url')
        if ($null -eq $url) { continue }
        if ((Get-JqStr (Get-JqPath $task @('pr', 'source'))) -ne 'meta') { continue }
        $recordedPrsAll.Add([ordered]@{ id = Get-JqNode $task 'id'; url = $url })
    }

    function Limit-Rows($Rows, [bool]$All, [long]$Limit) {
        $items = @($Rows)
        if ($All -or $items.Count -le $Limit) { return $items }
        if ($Limit -le 0) { return @() }
        return @($items[0..($Limit - 1)])
    }

    $model = [ordered]@{
        schema         = 'fm-bearings.v1'
        home           = $homeLabel
        generated      = $now
        prs            = $prStatus
        in_flight      = Limit-Rows $inFlightAll $allInFlight $inFlightN
        secondmates    = Limit-Rows $secondmatesAll $allSecondmates $secondmatesN
        decisions_open = Limit-Rows $decisionsAll $allDecisions $decisionsN
        landed         = @($done | ForEach-Object {
                [ordered]@{
                    id       = Get-JqNode $_ 'id'
                    what     = Get-JqTrunc (Get-JqNode $_ 'title') 70
                    artifact = Get-JqAlt (Get-JqAlt (Get-JqAlt (Get-JqNode $_ 'pr_url') (Get-JqNode $_ 'report_path')) (Get-JqNode $_ 'local_note')) '-'
                    owner    = Get-JqNode $_ 'home_id'
                }
            })
        gates          = Limit-Rows $gatesAll $allQueued $gatesN
        reports        = Limit-Rows $reportsAll $allReports $reportsN
        recorded_prs   = Limit-Rows $recordedPrsAll $allRecordedPrs $recordedPrsN
    }
    if ($unhealthyAll.Count -gt 0) {
        $model['unhealthy_endpoints'] = Limit-Rows $unhealthyAll $allUnhealthy $unhealthyN
    }
    if ($includePrs) { $model['candidate_prs'] = @($candidatePrs) }
    if ($fBodies) {
        $model['bodies'] = @(foreach ($record in $backlogRecords) {
                if ($true -ne (Get-JqNode $record 'structured')) { continue }
                $state = Get-JqStr (Get-JqNode $record 'state')
                if ($state -ne 'queued' -and $state -ne 'done') { continue }
                [ordered]@{
                    id   = Get-JqNode $record 'id'
                    body = Get-JqTrunc (Get-JqAlt (Get-JqAlt (Get-JqNode $record 'body_excerpt') (Get-JqNode $record 'raw')) '-') 200
                }
            })
    }
    if ($fPaths) {
        $model['paths'] = @(foreach ($task in $tasks) {
                [ordered]@{
                    id       = Get-JqNode $task 'id'
                    worktree = Get-JqAlt (Get-JqPath $task @('paths', 'worktree', 'path')) '-'
                    home     = Get-JqAlt (Get-JqPath $task @('paths', 'home', 'path')) '-'
                    status   = Get-JqPath $task @('paths', 'status_log', 'path')
                    report   = Get-JqPath $task @('paths', 'report', 'path')
                }
            })
    }
    if ($fActions) {
        $model['actions'] = @(foreach ($task in $tasks) {
                $actions = Get-JqNode $task 'actions'
                [ordered]@{
                    id    = Get-JqNode $task 'id'
                    watch = Get-JqAlt (Get-JqAlt (Get-JqNode $actions 'watch') (Get-JqNode $actions 'send')) '-'
                    steer = Get-JqAlt (Get-JqAlt (Get-JqNode $actions 'steer') (Get-JqNode $actions 'send')) '-'
                }
            })
    }
    if ($fEndpoints) {
        $model['endpoints'] = @(foreach ($task in $tasks) {
                $endpoint = Get-JqNode $task 'endpoint'
                [ordered]@{
                    id      = Get-JqNode $task 'id'
                    backend = Get-JqNode $task 'backend'
                    target  = Get-JqAlt (Get-JqNode $endpoint 'target') '-'
                    exists  = Get-JqNode $endpoint 'exists'
                    agent   = Get-JqNode $endpoint 'agent_alive'
                }
            })
    }

    # --- omitted[]: an absence is never ambiguous -----------------------------
    $omitted = [System.Collections.Generic.List[object]]::new()
    function Add-Omitted([string]$Surface, [string]$Reveal) {
        $omitted.Add([ordered]@{ surface = $Surface; reveal = $Reveal })
    }
    if (-not $fBodies) { Add-Omitted 'backlog item bodies' '--fields bodies' }
    if (-not $fPaths) { Add-Omitted 'task paths' '--fields paths' }
    if (-not $fActions) { Add-Omitted 'watch/steer actions' '--fields actions' }
    if (-not $fEndpoints) { Add-Omitted 'healthy endpoint detail' '--fields endpoints' }
    if (-not $allReports) { Add-Omitted 'full scout-report inventory' '--all-reports' }
    if (-not $allQueued) { Add-Omitted 'superseded queued items' '--all-queued' }
    if (-not $allLanded -and $perHomeCapped.Count -gt @($done).Count) {
        $mateHomes = @($done | ForEach-Object { Get-JqStr (Get-JqNode $_ 'home_id') } |
                Select-Object -Unique | Where-Object { $_ -cne '(main)' }).Count
        $extra = if ($mateHomes -gt 0) { " (incl. $mateHomes secondmate home(s))" } else { '' }
        Add-Omitted "landed showing $(@($done).Count) of $($perHomeCapped.Count)$extra" '--all-landed'
    }
    if (-not $allLanded -and $homeCapDropped -gt 0) {
        Add-Omitted "landed per-home capped at $landedPerHomeN for $homeCapDropped home(s)" '--all-landed'
    }
    $unreadable = @(Get-JqList $secondmateLanded 'unreadable')
    if ($unreadable.Count -gt 0) {
        Add-Omitted "secondmate home(s) with unreadable backlog: $($unreadable.Count)" 'inspect the listed secondmate home backlogs'
    }
    $truncatedLanded = @(Get-JqList $secondmateLanded 'truncated')
    if (-not $allLanded -and $truncatedLanded.Count -gt 0) {
        Add-Omitted "secondmate home Done capped at the snapshot layer for $($truncatedLanded.Count) home(s)" '--all-landed'
    }
    $orphan = @(Get-JqList $mainInventory 'orphan_in_flight')
    if ($orphan.Count -gt 0) {
        Add-Omitted "main in-flight backlog item(s) have no child metadata: $($orphan.Count)" 'inspect main data/backlog.md In flight vs state/*.meta'
    }
    $unstructured = Get-JqAlt (Get-JqNode $mainInventory 'unstructured_current_count') 0
    if ([long]$unstructured -gt 0) {
        Add-Omitted "main unstructured current backlog row(s): $unstructured" 'inspect main data/backlog.md In flight and Queued free-form rows'
    }
    if (-not $allInFlight -and $inFlightAll.Count -gt $inFlightN) {
        Add-Omitted "in_flight showing $inFlightN of $($inFlightAll.Count)" '--all-in-flight'
    }
    if (-not $allSecondmates -and $secondmatesAll.Count -gt $secondmatesN) {
        Add-Omitted "secondmates showing $secondmatesN of $($secondmatesAll.Count)" '--all-secondmates'
    }
    $mateTruncated = Get-JqAlt (Get-JqNode $secondmateCurrent 'truncated') 0
    if ([long]$mateTruncated -gt 0) {
        Add-Omitted "registered secondmates omitted by snapshot bound: $mateTruncated" 'raise FM_SNAPSHOT_SECONDMATES'
    }
    if ($true -eq (Get-JqNode $registry 'input_truncated')) {
        Add-Omitted 'secondmate registry input truncated by bounded read' 'raise FM_SNAPSHOT_REGISTRY_LINES or FM_SNAPSHOT_REGISTRY_BYTES'
    }
    if ($true -eq (Get-JqNode $registry 'records_truncated')) {
        Add-Omitted 'secondmate registry records omitted by bounded read' 'raise FM_SNAPSHOT_REGISTRY_RECORDS'
    }
    if ($false -eq (Get-JqNode $registry 'available')) {
        Add-Omitted ('secondmate registry unavailable: ' + (Get-JqStr (Get-JqAlt (Get-JqNode $registry 'reason') 'read failed'))) 'inspect data/secondmates.md'
    }
    $activityTruncated = 0
    $activityUnavailable = 0
    foreach ($mate in $secondmateRecords) {
        $scan = Get-JqPath $mate @('parent_event', 'activity_scan')
        if ($true -eq (Get-JqNode $scan 'input_truncated') -or $true -eq (Get-JqNode $scan 'retained_truncated')) {
            $activityTruncated++
        }
        if ($false -eq (Get-JqNode $scan 'available')) { $activityUnavailable++ }
    }
    if ($activityTruncated -gt 0) {
        Add-Omitted "secondmate parent activity evidence truncated for $activityTruncated record(s)" 'raise FM_SNAPSHOT_PARENT_ACTIVITY_LINES, FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, or FM_SNAPSHOT_PARENT_ACTIVITIES'
    }
    if ($activityUnavailable -gt 0) {
        Add-Omitted "secondmate parent activity evidence unavailable for $activityUnavailable record(s)" 'inspect the parent status logs'
    }
    if (-not $allDecisions -and $decisionsAll.Count -gt $decisionsN) {
        Add-Omitted "decisions_open showing $decisionsN of $($decisionsAll.Count)" '--all-decisions'
    }
    if (-not $allQueued -and $gatesAll.Count -gt $gatesN) {
        Add-Omitted "gates showing $gatesN of $($gatesAll.Count)" '--all-queued'
    }
    if (-not $allReports -and $reportsAll.Count -gt $reportsN) {
        Add-Omitted "reports showing $reportsN of $($reportsAll.Count)" '--all-reports'
    }
    if (-not $allRecordedPrs -and $recordedPrsAll.Count -gt $recordedPrsN) {
        Add-Omitted "recorded_prs showing $recordedPrsN of $($recordedPrsAll.Count)" '--all-recorded-prs'
    }
    if (-not $allUnhealthy -and $unhealthyAll.Count -gt $unhealthyN) {
        Add-Omitted "unhealthy_endpoints showing $unhealthyN of $($unhealthyAll.Count)" '--all-unhealthy'
    }
    if ($includePrs -and $prReposTotal -gt $prReposShown) {
        Add-Omitted "PR repositories showing $prReposShown of $prReposTotal" '--all-pr-repos'
    }
    if ($includePrs -and $prRowsCapped -gt 0) {
        Add-Omitted "candidate_prs showing $(@($candidatePrs).Count) of at least $prRowsMinTotal; capped in $prRowsCapped repo(s)" 'raise FM_BEARINGS_PR_LIMIT'
    }
    if (-not $includePrs) { Add-Omitted 'live PR discovery + checks' '--include-prs' }
    $model['omitted'] = @($omitted)

    if ($format -eq 'json') {
        Write-FmOut (ConvertTo-JqPretty $model 0)
        Exit-FmScript 0
    }
    Write-FmOut (ConvertTo-Toon $model)
    Exit-FmScript 0
}
