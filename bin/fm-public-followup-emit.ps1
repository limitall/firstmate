# bin/fm-public-followup-emit.ps1 - emit ONE structured terminal work result for
# work bound to a public commitment, into the owning home's private event inbox.
#
# Twin: bin/fm-public-followup-emit.sh
#
# WHY THIS EXISTS: a public promise is kept by the home that owns the relay
# consent and the thread binding. The home doing the work only has to report a
# TYPED result. Firstmate must never recover the source home, work id, outcome,
# or deliverables by parsing a free-form "done: ..." status sentence, so this
# script is the structured channel that carries them.
#
# WHAT IT DOES NOT DO: it never posts anything, never reads relay credentials,
# and never resolves a public thread. Outward delivery stays with the owning
# home (bin/fm-public-followup.sh deliver).
#
# Usage:
#   fm-public-followup-emit.ps1 --home <owning-home> \
#     --obligation <obligation-id> --relation <relation-id> \
#     --source-home <main|secondmate:<id>> --work-id <task-id> \
#     --generation <n> --outcome <outcome-type> \
#     [--deliverable <key>=<value>]... \
#     (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)
#
# Options:
#   --home <path>          The home that owns the public commitment (the primary
#                          that took the mention). Must already have a
#                          registration for --obligation; see
#                          `fm-public-followup.sh register`.
#   --obligation <id>      tasks-axi public-followup obligation id.
#   --relation <id>        The relation_id this work fulfills or contributes to.
#   --source-home <id>     This worker's stable home identity, exactly as bound:
#                          "main" or "secondmate:<stable-id>".
#   --work-id <id>         This worker's exact task id, exactly as bound.
#   --generation <n>       The bound relation generation (integer >= 1).
#   --outcome <type>       Typed outcome. tasks-axi owns the vocabulary and
#                          refuses anything it does not accept; this script only
#                          checks the token is a safe slug.
#   --deliverable k=v      Repeatable safe deliverable (for example
#                          pr_url=https://...). tasks-axi owns which keys a given
#                          expected-final type permits.
#   --outcome-text ...     Public-safe outcome sentence, from an argument, a
#                          file, or stdin ("-"). Collapsed to one line; the
#                          event builder bounds it by codepoint, so control
#                          characters cannot survive.
#
# Output: the event id on stdout. Exit 0 on a published or already-present event
# (both are successes: the id is derived, so re-emitting the same terminal result
# is a no-op), 2 on a usage or validation error, 1 on a publication failure.
#
# IDEMPOTENCY: the event id is a digest of the identity tuple (obligation,
# relation, source home, work id, generation, outcome type, deliverables), so a
# retry, a duplicate report, or a rerun after restart resolves to the same file
# and the first published copy wins. Nothing here needs coordination.
#
# SAFETY: the event is published through the shared private-artifact primitive -
# atomic rename into place, single link, mode 0600 (never executable), inside a
# 0700 directory this script refuses to create. The owning home must already have
# registered the obligation, so a home that never opted into the relay can never
# be given public-followup artifacts by a child.
#
# ---------------------------------------------------------------------------
# THE EVENT IS BYTES, NOT AN OBJECT: WHY THE JSON IS HAND-EMITTED
#
# The event id is a digest over the CANONICAL deliverables JSON, and the event
# file is read back by tasks-axi in the owning home, so the encoding is part of
# the interface rather than an implementation detail. The bash twin gets its
# canonical form from `jq -Sc` (sorted keys at every level, compact separators,
# no trailing newline inside the document); ConvertTo-Json produces neither that
# key order nor those separators, and would silently change every event id.
#
# So this twin emits the two documents itself, in the exact shape jq -Sc
# produces: keys in codepoint order, `{"k":v,...}` with no spaces, jq's string
# escaping (\" \\ \n \r \t and \u00XX for the remaining controls), and non-ASCII
# passed through as raw UTF-8. The top-level key order below is the sorted order
# written out literally, so a reader can check it against the bash twin's field
# list without running either.
#
# Two smaller shapes matter just as much:
#   - `from_entries` on duplicate deliverable keys keeps the LAST one, which is
#     why the builder assigns rather than adds.
#   - `$text[0:$max]` slices by CODEPOINT. .NET strings are UTF-16, so a naive
#     Substring would cut a surrogate pair in half and produce a different digest
#     for an emoji-bearing sentence. The slice below counts codepoints.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1') -Force

$fmArgv = @($args)
$fmSelf = $PSCommandPath

Invoke-FmMain -UnexpectedCode 70 {

    function Write-Usage {
        Write-FmErr 'usage: fm-public-followup-emit.ps1 --home <owning-home> --obligation <id> --relation <id>'
        Write-FmErr '         --source-home <main|secondmate:<id>> --work-id <id> --generation <n>'
        Write-FmErr '         --outcome <type> [--deliverable <key>=<value>]...'
        Write-FmErr '         (--outcome-text <text> | --outcome-text-file <path> | --outcome-text -)'
    }

    # `sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'`: the header comment
    # block IS the help text, so the two can never drift apart.
    function Write-Help {
        foreach ($line in ((Get-FmFileLines $fmSelf) | Select-Object -Skip 1)) {
            if (-not $line.StartsWith('#')) { break }
            Write-FmOut ($line -replace '^# ?', '')
        }
    }

    function Stop-Emit([string]$Message, [int]$Code = 2) {
        Write-FmErr "fm-public-followup-emit: $Message"
        Exit-FmScript $Code
    }

    # --- jq -Sc compatible encoding -----------------------------------------
    function ConvertTo-JqString([string]$Text) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        foreach ($ch in $Text.ToCharArray()) {
            switch ([int]$ch) {
                0x22 { [void]$sb.Append('\"'); continue }
                0x5C { [void]$sb.Append('\\'); continue }
                0x08 { [void]$sb.Append('\b'); continue }
                0x0C { [void]$sb.Append('\f'); continue }
                0x0A { [void]$sb.Append('\n'); continue }
                0x0D { [void]$sb.Append('\r'); continue }
                0x09 { [void]$sb.Append('\t'); continue }
                default {
                    if ([int]$ch -lt 0x20) {
                        [void]$sb.Append('\u{0:x4}' -f [int]$ch)
                    } else {
                        [void]$sb.Append($ch)
                    }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }

    # jq slices strings by codepoint; a surrogate pair is one codepoint.
    function Get-CodepointPrefix([string]$Text, [int]$Max) {
        if ($Max -le 0) { return '' }
        $count = 0
        $i = 0
        while ($i -lt $Text.Length) {
            if ($count -ge $Max) { break }
            $width = 1
            if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and
                [char]::IsLowSurrogate($Text[$i + 1])) { $width = 2 }
            $i += $width
            $count++
        }
        return $Text.Substring(0, $i)
    }

    # --- argv ----------------------------------------------------------------
    $homeDir = ''
    $obligation = ''
    $relation = ''
    $sourceHome = ''
    $workId = ''
    $generation = ''
    $outcome = ''
    $textSource = ''
    $textMode = ''
    $deliverableKeys = [System.Collections.Generic.List[string]]::new()
    $deliverableValues = [System.Collections.Generic.List[string]]::new()

    $first = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    if ($first -eq '--help' -or $first -eq '-h') { Write-Help; Exit-FmScript 0 }
    if ($fmArgv.Count -eq 0 -or $first -eq '') { Write-Usage; Exit-FmScript 2 }

    $i = 0
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        # `shift; VAR=${1:-}`: a flag at the end of argv yields the empty string
        # rather than an error, and the required-field checks refuse it below.
        $next = if (($i + 1) -lt $fmArgv.Count) { [string]$fmArgv[$i + 1] } else { '' }
        # -CaseSensitive: PowerShell's switch matches case-insensitively by
        # default, which would make `--HOME` a valid flag the bash twin refuses.
        switch -CaseSensitive ($arg) {
            '--home' { $homeDir = $next; $i++ }
            '--obligation' { $obligation = $next; $i++ }
            '--relation' { $relation = $next; $i++ }
            '--source-home' { $sourceHome = $next; $i++ }
            '--work-id' { $workId = $next; $i++ }
            '--generation' { $generation = $next; $i++ }
            '--outcome' { $outcome = $next; $i++ }
            '--outcome-text' { $textMode = 'inline'; $textSource = $next; $i++ }
            '--outcome-text-file' { $textMode = 'file'; $textSource = $next; $i++ }
            '--deliverable' {
                if ($next -notlike '*=*') {
                    Stop-Emit "--deliverable needs <key>=<value>, got '$next'"
                }
                $split = $next.IndexOf('=')
                $deliverableKeys.Add($next.Substring(0, $split))
                $deliverableValues.Add($next.Substring($split + 1))
                $i++
            }
            '--help' { Write-Help; Exit-FmScript 0 }
            '-h' { Write-Help; Exit-FmScript 0 }
            default { Stop-Emit "unknown argument '$arg'" }
        }
        $i++
    }

    foreach ($required in @($homeDir, $obligation, $relation, $sourceHome, $workId, $generation, $outcome, $textMode)) {
        if ([string]::IsNullOrEmpty($required)) { Write-Usage; Exit-FmScript 2 }
    }

    if (-not (Test-FmPfSlug $obligation)) { Stop-Emit "unsafe obligation id: $obligation" }
    if (-not (Test-FmPfSlug $relation)) { Stop-Emit "unsafe relation id: $relation" }
    if (-not (Test-FmPfSlug $workId)) { Stop-Emit "unsafe work id: $workId" }
    if (-not (Test-FmPfSlug $outcome)) { Stop-Emit "unsafe outcome type: $outcome" }
    if (-not (Test-FmPfHomeId $sourceHome)) {
        Stop-Emit "source home must be 'main' or 'secondmate:<stable-id>', got '$sourceHome'"
    }
    if ($generation -notmatch '^[0-9]+$') {
        Stop-Emit "generation must be a positive integer, got '$generation'"
    }
    if ([long]$generation -lt 1) { Stop-Emit "generation must be >= 1, got '$generation'" }

    for ($k = 0; $k -lt $deliverableKeys.Count; $k++) {
        $key = $deliverableKeys[$k]
        if ($key -notmatch '^[a-z0-9_]+$') {
            Stop-Emit "deliverable key must be lowercase [a-z0-9_], got '$key'"
        }
        if ($deliverableValues[$k].Length -gt 512) {
            Stop-Emit "deliverable '$key' exceeds 512 characters"
        }
        if ($deliverableValues[$k] -match '[\x00-\x1F\x7F]') {
            Stop-Emit "deliverable '$key' must be single-line text with no control characters"
        }
    }

    # Resolve the owning home to a real absolute directory before composing any
    # path under it. A native Windows absolute path counts as absolute here just
    # as a POSIX one does in the bash twin.
    if (-not ($homeDir.StartsWith('/') -or $homeDir -match '^[A-Za-z]:[\\/]')) {
        $resolved = $null
        try {
            $candidate = ConvertTo-FmNativePath $homeDir
            if ([System.IO.Directory]::Exists($candidate)) {
                $resolved = [System.IO.Path]::GetFullPath($candidate)
            }
        } catch { $resolved = $null }
        # The bash twin names `$1` in this diagnostic, which is unset by the time
        # the loop has consumed argv, so under `set -u` it aborts before printing
        # it. The message here names the argument the captain actually supplied;
        # the divergence is deliberate and cannot be differentially compared.
        if ($null -eq $resolved) { Stop-Emit "--home is not a reachable directory: $homeDir" }
        $homeDir = $resolved
    }
    $nativeHome = ConvertTo-FmNativePath $homeDir
    if (-not [System.IO.Directory]::Exists($nativeHome) -or (Test-FmSymlink $nativeHome)) {
        Stop-Emit "--home must name an existing directory, got '$homeDir'"
    }

    # A home that never opted into the relay is silently not given artifacts.
    if (-not (Test-FmPfRelayActive $homeDir)) { Exit-FmScript 0 }

    $state = "$homeDir/state"
    $registry = "$(Get-FmPfRegistryDir $state)/$obligation"
    $nativeRegistry = ConvertTo-FmNativePath $registry
    if (-not [System.IO.File]::Exists($nativeRegistry) -or (Test-FmSymlink $nativeRegistry)) {
        Stop-Emit ("home '$homeDir' has no public-followup registration for '$obligation'; " +
            'the owning home registers a commitment before its work can report one') 1
    }

    # The registration is the owning home's own record of what it bound, so
    # checking the identity tuple against it catches a mis-briefed worker at the
    # edge with a clear message. tasks-axi still re-validates everything at
    # consume time and remains the authority; this is a cheap early refusal.
    function Assert-RegistryMatch([string]$Field, [string]$Expected, [string]$Got) {
        if ([string]::IsNullOrEmpty($Expected)) { return }
        if ($Expected -eq $Got) { return }
        Stop-Emit "event $Field '$Got' does not match this home's registration ('$Expected')"
    }
    Assert-RegistryMatch 'relation' (Get-FmPfRegistryValue $state $obligation 'relation_id') $relation
    Assert-RegistryMatch 'source-home' (Get-FmPfRegistryValue $state $obligation 'work_home') $sourceHome
    Assert-RegistryMatch 'work-id' (Get-FmPfRegistryValue $state $obligation 'work_id') $workId
    Assert-RegistryMatch 'generation' (Get-FmPfRegistryValue $state $obligation 'generation') $generation

    $outcomeText = ''
    if ($textMode -eq 'inline') {
        $outcomeText = Get-FmPfCleanOutcomeText $textSource
    } else {
        if ($textSource -eq '-') {
            $outcomeText = Get-FmPfCleanOutcomeText ([Console]::In.ReadToEnd())
        } else {
            $nativeText = ConvertTo-FmNativePath $textSource
            if (-not [System.IO.File]::Exists($nativeText)) {
                Stop-Emit "outcome text file not found: $textSource"
            }
            $outcomeText = Get-FmPfCleanOutcomeText (Get-FmFileText $nativeText)
        }
    }
    if ([string]::IsNullOrEmpty($outcomeText)) {
        Stop-Emit 'outcome text is empty once whitespace and control characters are removed'
    }

    # Canonical deliverables object: last write wins per key (from_entries), then
    # codepoint-sorted keys, compact - so the same deliverables always hash to
    # the same identity regardless of flag order.
    $deliverables = @{}
    for ($k = 0; $k -lt $deliverableKeys.Count; $k++) {
        $deliverables[$deliverableKeys[$k]] = $deliverableValues[$k]
    }
    $sortedKeys = @($deliverables.Keys | Sort-Object -CaseSensitive)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $sortedKeys) {
        $parts.Add((ConvertTo-JqString $key) + ':' + (ConvertTo-JqString ([string]$deliverables[$key])))
    }
    $deliverablesJson = '{' + ($parts -join ',') + '}'

    $eventId = Get-FmPfEventId $obligation $relation $sourceHome $workId $generation $outcome $deliverablesJson
    # The derived id becomes a filename, so require the exact digest shape rather
    # than trusting whatever the hashing tool printed.
    if ([string]::IsNullOrEmpty($eventId) -or $eventId -notmatch '^[0-9a-f]+$' -or $eventId.Length -ne 64) {
        Stop-Emit 'could not derive a usable event id' 1
    }

    $occurredAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $boundedOutcome = Get-CodepointPrefix $outcomeText ([int](Get-FmPfOutcomeTextMax))

    # Top-level keys in `jq -S` order, written out literally.
    $eventJson = '{' + (@(
            '"deliverables":' + $deliverablesJson
            '"event_id":' + (ConvertTo-JqString $eventId)
            '"generation":' + $generation
            '"obligation_id":' + (ConvertTo-JqString $obligation)
            '"occurred_at":' + (ConvertTo-JqString $occurredAt)
            '"outcome_type":' + (ConvertTo-JqString $outcome)
            '"public_safe_outcome":' + (ConvertTo-JqString $boundedOutcome)
            '"relation_id":' + (ConvertTo-JqString $relation)
            '"schema_version":' + [string](Get-FmPfEventSchemaVersion)
            '"source_home_id":' + (ConvertTo-JqString $sourceHome)
            '"successor":null'
            '"work_id":' + (ConvertTo-JqString $workId)
        ) -join ',') + '}'

    $eventBytes = [System.Text.Encoding]::UTF8.GetByteCount($eventJson + "`n")
    $maxBytes = [int](Get-FmPfEventByteMax)
    if ($eventBytes -gt $maxBytes) {
        Stop-Emit "typed terminal event exceeds $maxBytes bytes" 2
    }

    $published = Publish-FmxPrivateArtifactOnce `
        -Directory (Get-FmPfEventsDir $state) -BaseName "$eventId.json" -Mode '600' -Text ($eventJson + "`n")
    # 0 published, 1 already present: both are successes because the id is
    # derived from the identity tuple and the first published copy wins.
    if ($published -eq 0 -or $published -eq 1) {
        Write-FmOut $eventId
        Exit-FmScript 0
    }
    Stop-Emit "could not publish the terminal event into $homeDir" 1
}
