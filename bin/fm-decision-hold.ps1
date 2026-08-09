# fm-decision-hold.ps1 - deterministic mechanics for durable captain decisions.
#
# Twin: bin/fm-decision-hold.sh
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.ps1 id <origin-id> <decision-key>
#   fm-decision-hold.ps1 hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.ps1 complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.ps1 verify <origin-id>
#   fm-decision-hold.ps1 resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# ---------------------------------------------------------------------------
# LOSING OR DUPLICATING A DECISION IS THE FAILURE MODE, SO THE REFUSALS ARE THE
# CONTRACT
#
# Every `fail` below exits 1 with a single-line diagnostic and changes nothing.
# Three shapes of refusal are load-bearing and are ported verbatim rather than
# consolidated, because each protects a different way a captain decision can go
# missing:
#
#   1. IDENTITY refusals (validate_slug, the title match, "is already durably
#      resolved; use a new decision key") stop one decision from being recorded
#      under another's name, which is how a duplicate is born.
#   2. INVENTORY refusals ("open structured decision X/Y has no captain-held
#      inventory entry") stop `complete` from attesting that a surface was
#      reviewed while a decision the status log still shows open has no durable
#      owner. That is the gate scout teardown depends on, so weakening it would
#      let teardown erase the source of an unanswered question.
#   3. RETRY-IDENTITY refusals (verify_resolution_identity) stop a re-run of
#      `resolve` from silently binding a DIFFERENT captain decision, or different
#      routed work, to a hold that already carries a partial resolution record.
#
# The ordering inside `resolve` is itself a safety property: the body is written,
# then the dependency edges are cleared, and the hold is closed last, so any
# failure before the final step leaves the captain hold OPEN. Nothing here may be
# reordered for tidiness.
#
# ---------------------------------------------------------------------------
# TWO STRING SHAPES THAT LOOK LIKE BUGS AND ARE NOT
#
#   The retry-identity prefix STARTS WITH A DOUBLE QUOTE. `tasks-axi show --full`
#   prints the body as a quoted scalar, so after the `  body: ` prefix is removed
#   the value still carries its opening quote, and the bash twin's prefix
#   includes it. Dropping it here would make every retry read as "no retry
#   identity record".
#
#   The newlines inside that body are LITERAL BACKSLASH-N, not line breaks: the
#   body is a single displayed line with escapes. So the field surgery below
#   splits on the two-character sequence \n, exactly as the bash twin's
#   `${var%%\\n*}` does, and must not be "fixed" to split on a real newline.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1') -Force

$fmArgv = @($args)
$fmSelf = $PSCommandPath

Invoke-FmMain -UnexpectedCode 70 {
    $script:Ord = [System.StringComparison]::Ordinal
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State
    $data = $context.Data
    $fmHome = $context.Home

    # Diagnostics name the home exactly as the bash twin spells it: the caller's
    # own FM_HOME / FM_ROOT_OVERRIDE string when set, and the POSIX script-derived
    # root otherwise. Printing the .NET-native form instead would make the same
    # refusal read differently depending on which twin produced it.
    $homeLabel = Get-FmEnv 'FM_HOME'
    if ([string]::IsNullOrEmpty($homeLabel)) { $homeLabel = Get-FmEnv 'FM_ROOT_OVERRIDE' }
    if ([string]::IsNullOrEmpty($homeLabel)) { $homeLabel = $context.PosixRoot }

    # `awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}'`: the header
    # comment block IS the usage text, so the two can never drift apart.
    function Get-Usage {
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-FmFileLines $fmSelf | Select-Object -Skip 1)) {
            if (-not $line.StartsWith('#')) { break }
            $out.Add(($line -replace '^# ?', ''))
        }
        return $out
    }
    function Write-Usage([switch]$ToError) {
        foreach ($line in (Get-Usage)) {
            if ($ToError) { Write-FmErr $line } else { Write-FmOut $line }
        }
    }
    function Stop-Hold([string]$Message) {
        Write-FmErr "fm-decision-hold: $Message"
        Exit-FmScript 1
    }
    function Stop-Usage {
        Write-Usage -ToError
        Exit-FmScript 2
    }

    function Assert-Slug([string]$Label, [string]$Value) {
        if ([string]::IsNullOrEmpty($Value) -or $Value -match '[^A-Za-z0-9._-]') {
            Stop-Hold "$Label must be a non-empty privacy-safe slug: $Value"
        }
    }
    function Assert-OneLine([string]$Label, [string]$Value) {
        if ([string]::IsNullOrEmpty($Value)) { Stop-Hold "$Label must not be empty" }
        if ($Value.Contains("`n") -or $Value.Contains("`r")) { Stop-Hold "$Label must be one line" }
    }

    function Get-Sha256Text([string]$Text) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        } finally { $sha.Dispose() }
    }

    function Get-HoldId([string]$Origin, [string]$Key) {
        Assert-Slug 'origin-id' $Origin
        Assert-Slug 'decision-key' $Key
        return "$Origin-decision-$Key"
    }

    # `(cd "$FM_HOME" && tasks-axi "$@")`: every backlog mutation runs in the
    # active home, which is what keeps main-home and secondmate-home ownership
    # aligned with the work that discovered the decision.
    function Invoke-TasksAxi([string[]]$Arguments) {
        try {
            return Invoke-FmTool -FilePath 'tasks-axi' -Arguments $Arguments -WorkingDirectory $fmHome
        } catch {
            # A missing tasks-axi is `command not found` in the bash twin - exit
            # 127, a plain failure the callers already handle. .NET raises
            # instead, so it is converted back into that failure rather than
            # escaping as an unexpected-defect exit.
            return @{ ExitCode = 127; StdOut = ''; StdErr = ''; Ok = $false }
        }
    }

    function Assert-TasksAxi {
        if (-not (Test-FmTasksAxiCompatible)) { Stop-Hold 'compatible tasks-axi is required' }
        $help = Invoke-TasksAxi @('hold', '--help')
        if (-not ($help.StdOut + $help.StdErr).Contains('--kind captain', $script:Ord)) {
            Stop-Hold 'tasks-axi does not expose the captain-hold contract'
        }
    }

    # Returns @{ Ok = <bool>; Text = <stdout> }; stderr is discarded exactly as
    # `2>/dev/null` does, so an absent item is a clean false rather than noise.
    function Get-TaskShow([string]$Id) {
        $result = Invoke-TasksAxi @('show', $Id, '--full')
        return @{ Ok = $result.Ok; Text = $result.StdOut }
    }

    # `sed -n "s/^  $field: //p" | head -1`: the FIRST line indented by exactly
    # two spaces whose key matches, value being everything after ": ".
    function Get-ShowField([string]$Text, [string]$Field) {
        $prefix = "  ${Field}: "
        foreach ($line in ($Text -replace "`r", '') -split "`n") {
            if ($line.StartsWith($prefix, $script:Ord)) { return $line.Substring($prefix.Length) }
        }
        return ''
    }

    function Test-OriginExistsHere([string]$Origin) {
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $state "$Origin.meta")))) { return $true }
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $data "$Origin/report.md")))) { return $true }
        return (Get-TaskShow $Origin).Ok
    }

    function Test-ListHasKey([string]$CommaList, [string]$Key) {
        return ",$CommaList,".Contains(",$Key,", $script:Ord)
    }

    # `sort -u` under LC_ALL=C is a BYTE sort. Sort-Object is culture-aware even
    # with -CaseSensitive, and a culture can reorder '-', '_' and '.' relative to
    # letters - which would change a key list's canonical form between the two
    # twins. StringComparer::Ordinal is the byte sort.
    function Get-SortedKeyUnion([string]$Existing, [string[]]$New) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $all = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($Existing -split ',') + @($New)) {
            if ([string]::IsNullOrEmpty($item)) { continue }
            if ($seen.Add($item)) { $all.Add($item) }
        }
        $all.Sort([System.StringComparer]::Ordinal)
        return ($all -join ',')
    }

    function Get-MetaValue([string]$MetaPath, [string]$Key) {
        return Get-FmMetaValue -MetaPath $MetaPath -Key $Key
    }

    function Get-OriginOpenDecisions([string]$Origin) {
        $meta = Join-Path $state "$Origin.meta"
        $statusFile = Join-Path $state "$Origin.status"
        $open = Get-FmStatusOpenDecisions $statusFile
        if ([string]::IsNullOrEmpty($open)) { return '' }
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) { return $open }
        $kind = Get-MetaValue $meta 'kind'
        if ([string]::IsNullOrEmpty($kind)) { $kind = 'ship' }
        if ($kind -ne 'secondmate') {
            $verb = Get-FmStatusLineVerb (Get-FmLastStatusLine $statusFile)
            if ($verb -eq 'done' -or $verb -eq 'failed') { return '' }
        }
        return $open
    }

    # Each record is key<TAB>verb<TAB>summary; only the key is consumed here.
    function Get-DecisionKeyList([string]$Records) {
        $out = [System.Collections.Generic.List[string]]::new()
        if ([string]::IsNullOrEmpty($Records)) { return $out }
        foreach ($line in (($Records -replace "`r", '') -split "`n")) {
            if ([string]::IsNullOrEmpty($line)) { continue }
            $key = @($line.Split("`t"))[0]
            if (-not [string]::IsNullOrEmpty($key)) { $out.Add($key) }
        }
        return $out
    }

    function Assert-HoldActive([string]$Id) {
        $show = Get-TaskShow $Id
        if (-not $show.Ok) { Stop-Hold "captain hold $Id is absent from $homeLabel/data/backlog.md" }
        $stateField = Get-ShowField $show.Text 'state'
        $held = Get-ShowField $show.Text 'held'
        $kind = Get-ShowField $show.Text 'kind'
        $holdKind = Get-ShowField $show.Text 'hold_kind'
        if ($stateField -ne 'queued') { Stop-Hold "captain hold $Id is not queued (state=$stateField)" }
        if ($held -ne 'yes') { Stop-Hold "captain hold $Id is not active" }
        if ($kind -ne 'captain') { Stop-Hold "backlog item $Id is not kind captain" }
        if ($holdKind -ne 'captain') { Stop-Hold "backlog item $Id is not held for the captain" }
    }

    # `case "$body" in *"Resolution recorded..."*"Routed work:"*)`: the second
    # marker must appear AFTER the first, so an ordered index test - not two
    # independent Contains calls.
    function Test-ResolutionBody([string]$Body) {
        $marker = $Body.IndexOf('Resolution recorded by fm-decision-hold.', $script:Ord)
        if ($marker -lt 0) { return $false }
        return ($Body.IndexOf('Routed work:', $marker, $script:Ord) -ge 0)
    }

    function Test-HoldResolved([string]$Id) {
        $show = Get-TaskShow $Id
        if (-not $show.Ok) { return $false }
        if ((Get-ShowField $show.Text 'state') -ne 'done') { return $false }
        if ((Get-ShowField $show.Text 'kind') -ne 'captain') { return $false }
        return (Test-ResolutionBody (Get-ShowField $show.Text 'body'))
    }

    function Assert-HoldDurable([string]$Id) {
        $show = Get-TaskShow $Id
        if (-not $show.Ok) { Stop-Hold "captain decision $Id is absent from $homeLabel/data/backlog.md" }
        $stateField = Get-ShowField $show.Text 'state'
        $held = Get-ShowField $show.Text 'held'
        $kind = Get-ShowField $show.Text 'kind'
        $holdKind = Get-ShowField $show.Text 'hold_kind'
        $body = Get-ShowField $show.Text 'body'
        if ($stateField -eq 'queued' -and $held -eq 'yes' -and $kind -eq 'captain' -and $holdKind -eq 'captain') {
            return
        }
        if ($stateField -eq 'done' -and $kind -eq 'captain' -and (Test-ResolutionBody $body)) { return }
        Stop-Hold "captain decision $Id is neither actively held nor durably resolved"
    }

    function Assert-ResolutionIdentity([string]$Id, [string]$Body, [string]$Digest, [string]$RoutedCsv) {
        # See the header: the prefix carries the body's own opening quote, and the
        # separators are the two-character sequence \n.
        $prefix = '"Resolution recorded by fm-decision-hold.\nDecision digest: '
        if (-not $Body.StartsWith($prefix, $script:Ord)) {
            Stop-Hold "captain hold $Id has no retry identity record"
        }
        $fields = $Body.Substring($prefix.Length)
        $routedMarker = '\nRouted identities: '
        $routedAt = $fields.IndexOf($routedMarker, $script:Ord)
        if ($routedAt -lt 0) { Stop-Hold "captain hold $Id has an invalid retry identity record" }
        if ($fields.IndexOf('\n\nCaptain decision:', $routedAt, $script:Ord) -lt 0) {
            Stop-Hold "captain hold $Id has an invalid retry identity record"
        }
        $digestEnd = $fields.IndexOf('\n', $script:Ord)
        $recordedDigest = if ($digestEnd -lt 0) { $fields } else { $fields.Substring(0, $digestEnd) }
        $rest = $fields.Substring($routedAt + $routedMarker.Length)
        $routesEnd = $rest.IndexOf('\n', $script:Ord)
        $recordedRoutes = if ($routesEnd -lt 0) { $rest } else { $rest.Substring(0, $routesEnd) }
        if ($recordedDigest -ne $Digest) { Stop-Hold "captain hold $Id records a different captain decision" }
        if ($recordedRoutes -ne $RoutedCsv) { Stop-Hold "captain hold $Id records different routed work" }
    }

    # `blocked_by` is quoted by tasks-axi when it holds several ids; strip the
    # quotes and all whitespace so edge ids compare exactly.
    function Get-BlockedBy([string]$ShowText) {
        $blocked = (Get-ShowField $ShowText 'blocked_by') -replace '\s', ''
        if ($blocked.StartsWith('"', $script:Ord)) { $blocked = $blocked.Substring(1) }
        if ($blocked.EndsWith('"', $script:Ord)) { $blocked = $blocked.Substring(0, $blocked.Length - 1) }
        return $blocked
    }

    # --- commands ------------------------------------------------------------

    function Invoke-CommandId([string[]]$Rest) {
        if ($Rest.Count -ne 2) { Stop-Usage }
        Write-FmOut (Get-HoldId $Rest[0] $Rest[1])
    }

    function Invoke-CommandHold([string[]]$Rest) {
        $origin = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
        $key = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
        if ($Rest.Count -lt 2) { Stop-Usage }
        $title = ''; $reason = ''; $repo = ''
        $i = 2
        while ($i -lt $Rest.Count) {
            $next = if (($i + 1) -lt $Rest.Count) { $Rest[$i + 1] } else { '' }
            switch -CaseSensitive ($Rest[$i]) {
                '--title' { $title = $next; $i++ }
                '--reason' { $reason = $next; $i++ }
                '--repo' { $repo = $next; $i++ }
                default { Stop-Usage }
            }
            $i++
        }
        Assert-Slug 'origin-id' $origin
        Assert-Slug 'decision-key' $key
        Assert-OneLine 'title' $title
        Assert-OneLine 'reason' $reason
        if ($reason.Contains('(') -or $reason.Contains(')')) {
            Stop-Hold 'reason must not contain parentheses (tasks-axi hold contract)'
        }
        Assert-TasksAxi
        if (-not (Test-OriginExistsHere $origin)) {
            Stop-Hold "origin $origin is not owned by the active home $homeLabel"
        }
        $id = Get-HoldId $origin $key
        $show = Get-TaskShow $id
        if ($show.Ok) {
            $stateField = Get-ShowField $show.Text 'state'
            $kind = Get-ShowField $show.Text 'kind'
            $existingTitle = Get-ShowField $show.Text 'title'
            if ($stateField -eq 'done') {
                Stop-Hold "captain decision $id is already durably resolved; use a new decision key for a new decision"
            }
            if ($kind -ne 'captain') { Stop-Hold "existing backlog identity $id is not kind captain" }
            if ($existingTitle -ne $title) { Stop-Hold "existing captain hold $id has a different title" }
        } else {
            $meta = Join-Path $state "$origin.meta"
            if ([string]::IsNullOrEmpty($repo) -and
                [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
                $repo = Get-MetaValue $meta 'project'
                $repo = $repo.TrimEnd('/')
                $slash = $repo.LastIndexOf('/')
                if ($slash -ge 0) { $repo = $repo.Substring($slash + 1) }
            }
            if ([string]::IsNullOrEmpty($repo)) { $repo = 'firstmate' }
            Assert-OneLine 'repo' $repo
            $body = "Origin: $origin`nDecision key: $key`nState: awaiting captain decision."
            $added = Invoke-TasksAxi @('add', $id, $title, '--kind', 'captain', '--repo', $repo, '--body', $body)
            if (-not $added.Ok) { Stop-Hold "could not create captain decision item $id" }
        }
        $heldResult = Invoke-TasksAxi @('hold', $id, '--reason', $reason, '--kind', 'captain')
        if (-not $heldResult.Ok) { Stop-Hold "could not activate captain hold $id" }
        Assert-HoldActive $id
        Write-FmOut $id
    }

    function Invoke-CommandComplete([string[]]$Rest) {
        $origin = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
        if ($Rest.Count -lt 2) { Stop-Usage }
        Assert-Slug 'origin-id' $origin
        $meta = Join-Path $state "$origin.meta"
        $hasMeta = [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))
        Assert-TasksAxi
        if (-not (Test-OriginExistsHere $origin)) {
            Stop-Hold "origin $origin is not owned by the active home $homeLabel"
        }

        $supplied = [System.Collections.Generic.List[string]]::new()
        # Ordinal: PowerShell's -eq on strings is case-insensitive, and `--NONE`
        # is not the attestation flag the bash twin accepts.
        if ($Rest.Count -eq 2 -and [string]::Equals($Rest[1], '--none', $script:Ord)) {
            # An explicit attestation that the reviewed surface has no unresolved
            # captain decision; it adds no keys but still runs every gate below.
        } else {
            for ($i = 1; $i -lt $Rest.Count; $i++) {
                if ([string]::Equals($Rest[$i], '--none', $script:Ord)) {
                    Stop-Hold '--none cannot be combined with decision keys'
                }
                Assert-Slug 'decision-key' $Rest[$i]
                $supplied.Add($Rest[$i])
            }
        }

        $previous = ''
        if ($hasMeta) { $previous = Get-MetaValue $meta 'decision_keys' }
        $keys = Get-SortedKeyUnion $previous $supplied.ToArray()
        if (-not [string]::IsNullOrEmpty($keys)) {
            foreach ($key in ($keys -split ',')) {
                if ([string]::IsNullOrEmpty($key)) { continue }
                Assert-HoldDurable (Get-HoldId $origin $key)
            }
        }

        $statusFile = Join-Path $state "$origin.status"
        $rawOpen = Get-FmStatusOpenDecisions $statusFile
        $open = Get-OriginOpenDecisions $origin
        foreach ($key in (Get-DecisionKeyList $open)) {
            if (-not (Test-ListHasKey $keys $key)) {
                Stop-Hold "open structured decision $origin/$key has no captain-held inventory entry"
            }
        }

        if ($hasMeta) {
            if ((Get-MetaValue $meta 'decisions_reviewed') -ne '1' -or $previous -ne $keys) {
                Add-FmFileLine -Path $meta -Line 'decisions_reviewed=1'
                Add-FmFileLine -Path $meta -Line "decision_keys=$keys"
            }

            # Transfer any still-open status decision to its durable backlog owner
            # so the live status fold does not duplicate the same Captain's Call
            # item.
            foreach ($key in (Get-DecisionKeyList $rawOpen)) {
                if (-not (Test-ListHasKey $keys $key)) { continue }
                Add-FmFileLine -Path $statusFile -Line ("captain-held [key=$key]: tracked by " + (Get-HoldId $origin $key))
            }
        }
        $suffix = if ([string]::IsNullOrEmpty($keys)) { '' } else { " ($keys)" }
        Write-FmOut "complete: $origin decision inventory reviewed$suffix"
    }

    function Invoke-CommandVerify([string[]]$Rest) {
        if ($Rest.Count -ne 1) { Stop-Usage }
        $origin = $Rest[0]
        Assert-Slug 'origin-id' $origin
        $meta = Join-Path $state "$origin.meta"
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
            Stop-Hold "origin metadata is absent: $meta"
        }
        Assert-TasksAxi
        if ((Get-MetaValue $meta 'decisions_reviewed') -ne '1') {
            Stop-Hold "origin $origin has no completed unresolved-decision inventory"
        }
        $keys = Get-MetaValue $meta 'decision_keys'
        if (-not [string]::IsNullOrEmpty($keys)) {
            foreach ($key in ($keys -split ',')) {
                if ([string]::IsNullOrEmpty($key)) { continue }
                Assert-HoldDurable (Get-HoldId $origin $key)
            }
        }
        foreach ($key in (Get-DecisionKeyList (Get-OriginOpenDecisions $origin))) {
            if (-not (Test-ListHasKey $keys $key)) {
                Stop-Hold "open structured decision $origin/$key is outside the reviewed inventory"
            }
            Assert-HoldDurable (Get-HoldId $origin $key)
        }
        Write-FmOut "verified: $origin unresolved-decision inventory"
    }

    function Invoke-CommandResolve([string[]]$Rest) {
        $origin = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
        $key = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
        if ($Rest.Count -lt 2) { Stop-Usage }
        $decisionFile = ''
        $routedList = [System.Collections.Generic.List[string]]::new()
        $i = 2
        while ($i -lt $Rest.Count) {
            $next = if (($i + 1) -lt $Rest.Count) { $Rest[$i + 1] } else { '' }
            switch -CaseSensitive ($Rest[$i]) {
                '--decision-file' { $decisionFile = $next; $i++ }
                '--routed-to' {
                    Assert-Slug 'routed-task' $next
                    $routedList.Add($next)
                    $i++
                }
                default { Stop-Usage }
            }
            $i++
        }
        Assert-Slug 'origin-id' $origin
        Assert-Slug 'decision-key' $key
        if ([string]::IsNullOrEmpty($decisionFile)) { Stop-Hold '--decision-file is required' }
        $nativeDecision = ConvertTo-FmNativePath $decisionFile
        if (-not [System.IO.File]::Exists($nativeDecision)) {
            Stop-Hold "decision file does not exist: $decisionFile"
        }
        # `decision=$(cat file)`: command substitution strips TRAILING newlines,
        # and the digest is taken over exactly those bytes.
        $decision = (Get-FmFileText $nativeDecision).TrimEnd("`n")
        if ([string]::IsNullOrEmpty($decision)) { Stop-Hold 'decision file must not be empty' }
        if ([System.Text.Encoding]::UTF8.GetByteCount($decision) -gt 8192) {
            Stop-Hold 'decision file exceeds 8192 bytes'
        }
        if ($routedList.Count -eq 0) { Stop-Hold 'at least one --routed-to task is required' }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $routed = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $routedList) { if ($seen.Add($item)) { $routed.Add($item) } }
        $routed.Sort([System.StringComparer]::Ordinal)
        $routedSpace = ($routed -join ' ')
        $routedCsv = ($routed -join ',')
        $digest = Get-Sha256Text $decision
        Assert-TasksAxi
        $id = Get-HoldId $origin $key

        if (Test-HoldResolved $id) {
            $holdBody = Get-ShowField (Get-TaskShow $id).Text 'body'
            Assert-ResolutionIdentity $id $holdBody $digest $routedCsv
            Write-FmOut "resolved: $id"
            return
        }
        Assert-HoldActive $id
        $holdBody = Get-ShowField (Get-TaskShow $id).Text 'body'
        $resolutionRecorded = $false
        if ($holdBody.Contains('Resolution recorded by fm-decision-hold.', $script:Ord)) {
            Assert-ResolutionIdentity $id $holdBody $digest $routedCsv
            $resolutionRecorded = $true
        }

        foreach ($dep in $routed) {
            $show = Get-TaskShow $dep
            if (-not $show.Ok) { Stop-Hold "routed task $dep does not exist in the active home" }
            if ((Get-ShowField $show.Text 'state') -eq 'done' -and -not $resolutionRecorded) {
                Stop-Hold "routed task $dep is already done"
            }
            $blocked = Get-BlockedBy $show.Text
            if (-not ",$blocked,".Contains(",$id,", $script:Ord)) {
                # A dependency already cleared by an earlier partial run is proved
                # by the recorded body, not re-derived from the edge.
                $marker = $holdBody.IndexOf('Resolution recorded by fm-decision-hold.', $script:Ord)
                $ok = ($marker -ge 0) -and ($holdBody.IndexOf("- $dep", $marker, $script:Ord) -ge 0)
                if (-not $ok) { Stop-Hold "routed task $dep is not durably blocked by $id" }
            }
        }

        $body = "Resolution recorded by fm-decision-hold.`nDecision digest: $digest`n" +
                "Routed identities: $routedCsv`n`nCaptain decision:`n$decision`n`nRouted work:`n"
        foreach ($dep in $routed) { $body += "- $dep`n" }
        $updated = Invoke-TasksAxi @('update', $id, '--body', $body)
        if (-not $updated.Ok) { Stop-Hold "could not record the captain decision on $id" }
        foreach ($dep in $routed) {
            $show = Get-TaskShow $dep
            if (-not $show.Ok) { Stop-Hold "routed task $dep disappeared before routing" }
            $blocked = Get-BlockedBy $show.Text
            if (",$blocked,".Contains(",$id,", $script:Ord)) {
                $unblocked = Invoke-TasksAxi @('unblock', $dep, '--by', $id)
                if (-not $unblocked.Ok) { Stop-Hold "could not route the recorded decision to $dep" }
            }
        }
        $done = Invoke-TasksAxi @('done', $id)
        if (-not $done.Ok) { Stop-Hold "could not close resolved captain hold $id" }
        if (-not (Test-HoldResolved $id)) {
            Stop-Hold "captain hold $id did not retain its durable resolution record"
        }
        Write-FmOut "resolved: $id -> $routedSpace"
    }

    $verb = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    $rest = @(if ($fmArgv.Count -gt 1) { $fmArgv[1..($fmArgv.Count - 1)] } else { @() })
    switch -CaseSensitive ($verb) {
        'id' { Invoke-CommandId $rest }
        'hold' { Invoke-CommandHold $rest }
        'complete' { Invoke-CommandComplete $rest }
        'verify' { Invoke-CommandVerify $rest }
        'resolve' { Invoke-CommandResolve $rest }
        '-h' { Write-Usage }
        '--help' { Write-Usage }
        default { Stop-Usage }
    }
    Exit-FmScript 0
}
