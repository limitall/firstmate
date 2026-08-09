# Twin: bin/fm-public-followup.sh
# fm-public-followup.sh - the deterministic consumer and delivery owner for
# public commitments made through the myfirstmate relay (X and Discord).
#
# THE PROBLEM THIS SOLVES: firstmate promises a public final reply, routes the
# work out, and then the conversation compacts or the session restarts. Nothing
# in memory survives, so the promise is only kept if reconciling it is a disk
# operation. Every command here reads durable state and nothing else.
#
# OWNERSHIP BOUNDARIES (do not re-implement any of these here):
#   tasks-axi public-followup   the typed obligation and its state machine.
#   state/x-context/            the private full request context (fm-x-lib.sh).
#   bin/fm-x-reply.sh           posting to the relay, thread splitting, dry run.
#   bin/fm-public-followup-lib.sh  the activation gate and private transport.
# This script composes them; it never restates their contracts or schemas.
#
# ZERO OVERHEAD FOR HOMES THAT DO NOT USE THE RELAY: every subcommand gates
# first on the authoritative activation contract (a non-empty FMX_PAIRING_TOKEN
# in $FM_HOME/.env). Read-side and cleanup paths then use an O(1) presence check
# for registrations this home actually created. A relay-disabled home therefore
# runs one [ -f ] test before any backlog work: no tasks-axi call, no backlog scan,
# and no file created. Silent read-side commands return without output; commands
# that require an active relay report their configuration error after the same
# gate. A relay-enabled home with no live commitments stops at the second gate
# for the same cost.
#
# Usage:
#   fm-public-followup.sh active
#       Silent gate probe. Exit 0 when this home has live public-followup work
#       worth looking at, 1 otherwise. Safe to call unconditionally.
#
#   fm-public-followup.sh register <obligation-id> --relation <relation-id>
#         --work-home <main|secondmate:<id>> --work-id <task-id> --generation <n>
#         [--platform <x|discord>] [--request <request-id>]
#       Record the binding the relay path just created with `tasks-axi
#       public-followup add` + `bind-work`. This is the event-driven
#       registration: it creates this home's private public-followup directories
#       (0700) and the bounded public-safe registration record, which is what
#       later makes the presence checks O(1) and lets bound work report a typed
#       terminal result. Refuses when the relay is not active for this home.
#
#   fm-public-followup.sh brief <obligation-id>
#       Print the exact fm-public-followup-emit.sh command line the bound worker
#       must run when its work reaches the promised terminal outcome, so the
#       binding is copied into a brief instead of hand-assembled.
#
#   fm-public-followup.sh consume
#       Drain every pending typed terminal event: validate its derived identity,
#       skip anything already accepted, apply `tasks-axi public-followup
#       work-event`, and quarantine what tasks-axi refuses. Prints one
#       "ready <obligation-id> <request-id> <platform>" line per obligation that
#       became delivery-ready, and one "rejected <event-id>: <reason>" line per
#       refusal. Silent when there is nothing to do. Duplicate events and restart
#       replay are no-ops.
#
#   fm-public-followup.sh pending
#       One bounded public-safe line per unresolved commitment, for the session
#       start digest. Prunes registrations whose obligation is already closed.
#       Silent when nothing is unresolved.
#
#   fm-public-followup.sh deliver <obligation-id> [--text-file <path>]
#       Post the final public reply into the ORIGINAL thread and close the
#       obligation. Uses the stored platform and opaque context binding, so the
#       destination is never guessed. Without --text-file the accepted terminal
#       event's bounded public-safe outcome is reused exactly, which keeps the
#       common path deterministic. The sequence is begin-delivery with the
#       payload hash, post, then record the posted receipt or a typed error.
#       A validated receipt also clears any bound legacy X link before the
#       registration is removed.
#       An already-posted obligation is an idempotent success without another
#       post; an obligation left in delivery-posting by a crash is REFUSED
#       rather than posted again.
#
#   fm-public-followup.sh record-posted <obligation-id> --attempt <n> --chunks <n>
#       Close an obligation whose post is known to have landed on exactly
#       attempt <n> with exactly <n> messages, without posting anything. This is
#       the late-receipt path: use it when a post succeeded but its receipt was
#       lost, never to paper over an unknown outcome.
#
#   fm-public-followup.sh guard-work <work-home-id> <work-id>
#       Exit 3 when this home has an unresolved public commitment bound to that
#       exact work, printing one line per blocking obligation. Exit 0 otherwise.
#       Cleanup paths call this so bound work is never treated as finished while
#       its public promise is still open.
#
#   fm-public-followup.sh retire <obligation-id> [--force]
#       Drop the registration once its obligation is closed. --force is the
#       explicit discard-approved escape hatch for an unresolved or missing
#       obligation.
#
# Requires a compatible tasks-axi for registration, reconciliation, delivery,
# cleanup guards, and retirement; `active` and `brief` only inspect local state.
# FM_PF_RETRY_BACKOFF_SECS (default 900) sets the next-attempt time recorded with
# a retryable delivery error.

#Requires -Version 7.0

# ---------------------------------------------------------------------------
# WHAT DIFFERS FROM THE BASH TWIN, AND WHY (kept BELOW the help sentinel so the
# printed --help stays byte-identical to the twin's)
#
#   NO jq. The bash twin requires jq for every payload read and refuses without
#   it; ConvertFrom-Json -AsHashtable does that work in-process, so jq is neither
#   used nor demanded (docs/powershell-port.md). tasks-axi remains required
#   exactly as before, because it owns the obligation state machine.
#
#   tasks-axi IS RESOLVED THROUGH Get-Command before it runs, and runs with its
#   working directory set to FM_HOME - the same `(cd "$FM_HOME" && tasks-axi ...)`
#   convention. Windows CreateProcess appends only ".exe" to a bare name, so a
#   tasks-axi published under any other PATHEXT extension would otherwise be
#   invisible to Process.Start while `command -v` still finds it.
#
#   THE SIBLING SCRIPTS ARE REACHED THROUGH Invoke-FmScript rather than through a
#   hard-coded "$FM_ROOT/bin/<name>.sh", so the execute edge is correct whichever
#   side of the conversion the sibling is on (contract 7). Their stderr is
#   re-emitted verbatim, because the bash twin redirects only their stdout.
#
#   THE PRINTED HELP IS THIS FILE'S OWN HEADER, exactly as the twin's `sed`
#   trick prints its own - so the two can never drift apart.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

$fmArgv = @($args)
$script:FmPfTempFiles = [System.Collections.Generic.List[string]]::new()

function Write-FmPfUsage {
    [CmdletBinding()]
    param()
    Write-FmErr 'usage: fm-public-followup.sh <active|register|brief|consume|pending|deliver|record-posted|guard-work|retire> [args]'
}

# The header comment IS the help text, so the two can never drift apart - the
# twin of `sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'`, with
# `#Requires -Version 7.0` standing in for `set -u` as the end sentinel.
function Write-FmPfHelp {
    [CmdletBinding()]
    param()
    $lines = Get-FmFileLines $PSCommandPath
    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq '#Requires -Version 7.0') { break }
        $line = $lines[$i]
        if ($line.StartsWith('# ')) {
            $body.Add($line.Substring(2))
        } elseif ($line.StartsWith('#')) {
            $body.Add($line.Substring(1))
        } else {
            $body.Add($line)
        }
    }
    while ($body.Count -gt 0 -and $body[$body.Count - 1] -ceq '') { $body.RemoveAt($body.Count - 1) }
    foreach ($line in $body) { Write-FmOut $line }
}

function Exit-FmPfDie {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][int]$Code = 2
    )
    Write-FmErr "fm-public-followup: $Message"
    Exit-FmScript $Code
}

function Get-FmPfNowRfc3339 {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ",
        [System.Globalization.CultureInfo]::InvariantCulture)
}

# The retry time recorded with a retryable delivery error. The bash twin tries
# BSD and GNU date in turn and prints nothing when neither works; .NET has one
# spelling, so this always answers.
function Get-FmPfNextAttemptRfc3339 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][long]$BackoffSeconds)
    return [DateTime]::UtcNow.AddSeconds($BackoffSeconds).ToString("yyyy-MM-ddTHH:mm:ssZ",
        [System.Globalization.CultureInfo]::InvariantCulture)
}

# jq's `.a.b.c // empty` over a parsed record: '' for any missing or null step,
# never a throw under StrictMode.
function Get-FmPfField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Record,
        [Parameter(Mandatory)][string]$Path
    )
    $node = $Record
    foreach ($part in $Path.Split('.')) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        if ($node -isnot [System.Collections.IDictionary]) { return '' }
        if (-not $node.Contains($part)) { return '' }
        $node = $node[$part]
    }
    if ($null -eq $node) { return '' }
    if ($node -is [bool]) { return $(if ($node) { 'true' } else { '' }) }
    if ($node -is [string]) { return $node }
    if ($node -is [double] -or $node -is [decimal]) {
        $d = [double]$node
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e18) {
            return ([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($node -is [System.Collections.IDictionary] -or $node -is [System.Collections.IList]) { return '' }
    return [string]$node
}

# jq -Sc: compact JSON with every object's keys sorted, which is what the derived
# event identity is hashed over. Sorting is ORDINAL, matching jq's codepoint
# order, and the rendering goes through ConvertTo-Json (verified on this host to
# leave < > & unescaped, unlike Windows PowerShell 5).
function ConvertTo-FmPfSortedJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    return (ConvertTo-Json -InputObject (ConvertTo-FmPfSortedValue -Value $Value) -Depth 20 -Compress)
}

function ConvertTo-FmPfSortedValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $out = [ordered]@{}
        foreach ($key in $keys) { $out[$key] = ConvertTo-FmPfSortedValue -Value $Value[$key] }
        return $out
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        return @(foreach ($item in $Value) { ConvertTo-FmPfSortedValue -Value $item })
    }
    return $Value
}

function New-FmPfTempFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin runs mktemp unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive reconciliation.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prefix)
    $root = ConvertTo-FmNativePath (Get-FmEnv 'TMPDIR' ([System.IO.Path]::GetTempPath()))
    $path = [System.IO.Path]::Combine($root, $Prefix + [System.IO.Path]::GetRandomFileName())
    try {
        Set-FmFileText -Path $path -Text '' -NoNewline
    } catch {
        return $null
    }
    $script:FmPfTempFiles.Add($path)
    return $path
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $fmRoot = $ctx.Root
    $fmHome = $ctx.Home
    $state = $ctx.State
    $data = $ctx.Data
    $binDir = Join-Path $fmRoot 'bin'

    $retryBackoff = Get-FmEnv 'FM_PF_RETRY_BACKOFF_SECS' '900'
    if (-not [regex]::IsMatch($retryBackoff, '^[0-9]+\z')) { $retryBackoff = '900' }
    $retryBackoffValue = [long]$retryBackoff

    # Every tasks-axi call runs from the home whose backlog owns the obligation,
    # the same convention bin/fm-decision-hold.sh uses for typed backlog state.
    $invokeTasks = {
        param([string[]]$TaskArgs)
        $tool = Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $tool) { return @{ ExitCode = 127; StdOut = ''; StdErr = ''; Ok = $false } }
        return (Invoke-FmTool -FilePath $tool.Source -Arguments $TaskArgs -WorkingDirectory $fmHome)
    }

    $requireTools = {
        if ($null -eq (Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)) {
            Exit-FmPfDie 'tasks-axi is required' 1
        }
    }

    # The complete typed obligation payload, empty when the backlog simply has no
    # such public-followup item, and Ok=$false ONLY when the backlog could not be
    # read at all. Callers depend on that distinction to report the right thing.
    # tasks-axi stays the single source of truth; the registration record is never
    # consulted for state.
    $obligationJson = {
        param([string]$Id)
        $result = & $invokeTasks @('public-followup', 'list', '--json')
        if (-not $result.Ok) { return @{ Ok = $false; Payload = $null } }
        if ([string]::IsNullOrEmpty($result.StdOut)) { return @{ Ok = $false; Payload = $null } }
        $listing = $null
        try { $listing = $result.StdOut | ConvertFrom-Json -AsHashtable } catch { return @{ Ok = $false; Payload = $null } }
        if ($listing -isnot [System.Collections.IDictionary]) { return @{ Ok = $true; Payload = $null } }
        if (-not $listing.Contains('public_followups')) { return @{ Ok = $true; Payload = $null } }
        foreach ($entry in @($listing['public_followups'])) {
            if ($entry -isnot [System.Collections.IDictionary]) { continue }
            if ($entry.Contains('id') -and [string]$entry['id'] -ceq $Id) {
                return @{ Ok = $true; Payload = $entry }
            }
        }
        return @{ Ok = $true; Payload = $null }
    }

    # --- shared helpers over the registration records -------------------------

    $registrationValid = {
        param([string]$Id)
        $file = ConvertTo-FmNativePath "$(Get-FmPfRegistryDir $state)/$Id"
        if (-not [System.IO.File]::Exists($file)) { return $false }
        if (Test-FmSymlink $file) { return $false }
        $relation = Get-FmPfRegistryValue $state $Id 'relation_id'
        $workHome = Get-FmPfRegistryValue $state $Id 'work_home'
        $workId = Get-FmPfRegistryValue $state $Id 'work_id'
        $generation = Get-FmPfRegistryValue $state $Id 'generation'
        if ([string]::IsNullOrEmpty([string]$relation) -or [string]::IsNullOrEmpty([string]$workId)) { return $false }
        if (-not (Test-FmPfHomeId $workHome)) { return $false }
        if (-not (Test-FmPfSlug $workId)) { return $false }
        if (-not [regex]::IsMatch([string]$generation, '^[0-9]+\z')) { return $false }
        return $true
    }

    $secondmateHome = {
        param([string]$Id)
        if (-not (Test-FmPfHomeId "secondmate:$Id")) { return $null }
        $meta = "$state/$Id.meta"
        $recorded = Get-FmxMetaValue -MetaPath $meta -Key 'home'
        $registry = "$data/secondmates.md"
        $registryNative = ConvertTo-FmNativePath $registry
        if ([string]::IsNullOrEmpty($recorded) -and [System.IO.File]::Exists($registryNative) -and
            -not (Test-FmSymlink $registryNative)) {
            $recorded = Get-FmSecondmateRegistryField $registry $Id 'home'
        }
        if ([string]::IsNullOrEmpty([string]$recorded)) { return $null }
        # `case "$home" in /*)` - a recorded home must be an absolute POSIX path
        # during the transition (docs/powershell-port.md contract 3).
        if (-not ([string]$recorded).StartsWith('/')) { return $null }
        $native = ConvertTo-FmNativePath $recorded
        if (-not [System.IO.Directory]::Exists($native)) { return $null }
        try { $native = [System.IO.Path]::GetFullPath($native) } catch { return $null }
        $marker = [System.IO.Path]::Combine($native, '.fm-secondmate-home')
        if (-not [System.IO.File]::Exists($marker)) { return $null }
        if (Test-FmSymlink $marker) { return $null }
        $lines = Get-FmFileLines $marker
        if ($lines.Length -lt 1 -or $lines[0] -cne $Id) { return $null }
        return $native
    }

    $clearLegacyLink = {
        param([string]$Id)
        if (-not (& $registrationValid $Id)) { return $false }
        $workHome = [string](Get-FmPfRegistryValue $state $Id 'work_home')
        $workId = [string](Get-FmPfRegistryValue $state $Id 'work_id')
        if ([string]::IsNullOrEmpty($workHome) -or [string]::IsNullOrEmpty($workId)) { return $false }
        $targetHome = ''
        $targetState = ''
        if ($workHome -ceq 'main') {
            $targetHome = $fmHome
            $targetState = $state
        } elseif ($workHome.StartsWith('secondmate:', [System.StringComparison]::Ordinal)) {
            $targetHome = & $secondmateHome $workHome.Substring('secondmate:'.Length)
            if ($null -eq $targetHome) { return $false }
            $targetState = "$targetHome/state"
        } else {
            return $false
        }
        $saved = @{}
        foreach ($pair in @(
                @{ Name = 'FM_HOME'; Value = $targetHome },
                @{ Name = 'FM_STATE_OVERRIDE'; Value = $targetState },
                @{ Name = 'FM_ROOT_OVERRIDE'; Value = $fmRoot })) {
            $saved[$pair.Name] = [Environment]::GetEnvironmentVariable($pair.Name)
            [Environment]::SetEnvironmentVariable($pair.Name, $pair.Value)
        }
        $result = $null
        try {
            $result = Invoke-FmScript -Name 'fm-x-followup' -BinDir $binDir `
                -Arguments @('--clear', $workId)
        } finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
        if (-not [string]::IsNullOrEmpty([string]$result.StdErr)) {
            [Console]::Error.Write([string]$result.StdErr)
        }
        return ($result.ExitCode -eq 0)
    }

    $removeRegistration = {
        param([string]$Id)
        try {
            [System.IO.File]::Delete(
                [System.IO.Path]::Combine((ConvertTo-FmNativePath (Get-FmPfRegistryDir $state)), $Id))
        } catch {
            $null = $_
        }
    }

    # 0 when some bound work still carries an x_request link, 1 when none does,
    # 2 when the relations cannot be read at all - the three answers the deliver
    # path's already-delivered branch distinguishes.
    $legacyLinkStatus = {
        param($Payload)
        $relations = $null
        if ($Payload -is [System.Collections.IDictionary] -and $Payload.Contains('public_followup')) {
            $followup = $Payload['public_followup']
            if ($followup -is [System.Collections.IDictionary] -and $followup.Contains('work_relations')) {
                $relations = $followup['work_relations']
            }
        }
        if ($null -eq $relations -or $relations -isnot [System.Collections.IList]) { return 2 }
        $rows = @($relations)
        if ($rows.Count -eq 0) { return 2 }
        foreach ($relation in $rows) {
            if ($relation -isnot [System.Collections.IDictionary]) { return 2 }
            $workHome = Get-FmPfField -Record $relation -Path 'work_ref.home_id'
            $workId = Get-FmPfField -Record $relation -Path 'work_ref.task_id'
            if ([string]::IsNullOrEmpty($workHome) -or [string]::IsNullOrEmpty($workId)) { return 2 }
            $targetHome = ''
            if ($workHome -ceq 'main') {
                $targetHome = $fmHome
            } elseif ($workHome.StartsWith('secondmate:', [System.StringComparison]::Ordinal)) {
                $targetHome = & $secondmateHome $workHome.Substring('secondmate:'.Length)
                if ($null -eq $targetHome) { return 2 }
            } else {
                return 2
            }
            $meta = "$targetHome/state/$workId.meta"
            $metaNative = ConvertTo-FmNativePath $meta
            $present = [System.IO.File]::Exists($metaNative) -or
                       [System.IO.Directory]::Exists($metaNative) -or (Test-FmSymlink $metaNative)
            if (-not $present) { continue }
            if (-not [System.IO.File]::Exists($metaNative) -or (Test-FmSymlink $metaNative)) { return 2 }
            if (-not [string]::IsNullOrEmpty((Get-FmxMetaValue -MetaPath $metaNative -Key 'x_request'))) {
                return 0
            }
        }
        return 1
    }

    $recordError = {
        param([string]$Id, [string]$Attempt, [string]$DeliveryState, [string]$Code, [string]$Next)
        $temp = New-FmPfTempFile -Prefix 'fm-pf-error.'
        if ($null -eq $temp) { return $false }
        $record = [ordered]@{
            state         = $DeliveryState
            attempt_count = [long]$Attempt
            error_code    = $Code
            occurred_at   = Get-FmPfNowRfc3339
        }
        if (-not [string]::IsNullOrEmpty($Next)) { $record['next_attempt_at'] = $Next }
        Set-FmFileText -Path $temp -Text ((ConvertTo-Json -InputObject $record -Depth 20 -Compress) + "`n")
        $result = & $invokeTasks @('public-followup', 'record-error', $Id, '--error-file', $temp)
        try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
        return [bool]$result.Ok
    }

    $recordPosted = {
        param([string]$Id, [string]$Attempt, [string]$Request, [string]$Platform, [string]$Chunks)
        $temp = New-FmPfTempFile -Prefix 'fm-pf-receipt.'
        if ($null -eq $temp) { return $false }
        $record = [ordered]@{
            state          = 'posted'
            request_id     = $Request
            platform       = $Platform
            attempt_count  = [long]$Attempt
            total_chunks   = [long]$Chunks
            posted_chunks  = [long]$Chunks
            posted_at      = Get-FmPfNowRfc3339
        }
        Set-FmFileText -Path $temp -Text ((ConvertTo-Json -InputObject $record -Depth 20 -Compress) + "`n")
        $result = & $invokeTasks @('public-followup', 'record-delivery', $Id, '--receipt-file', $temp)
        try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
        return [bool]$result.Ok
    }

    # The shared silent gate for every read-side subcommand: exits 0 with no
    # output when this home has no public-followup work, so callers can invoke
    # unconditionally without a relay-disabled home paying anything.
    $gateOrExit = {
        if (-not (Test-FmPfRelayActive $fmHome)) { Exit-FmScript 0 }
        if (-not (Test-FmPfHasRegistration $state) -and -not (Test-FmPfHasEvent $state)) {
            Exit-FmScript 0
        }
    }

    try {
        $cmd = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
        if ($cmd -ceq '--help' -or $cmd -ceq '-h' -or $cmd -ceq 'help') {
            Write-FmPfHelp
            Exit-FmScript 0
        }
        if ([string]::IsNullOrEmpty($cmd)) {
            Write-FmPfUsage
            Exit-FmScript 2
        }
        $rest = @()
        if ($fmArgv.Count -gt 1) { $rest = @($fmArgv[1..($fmArgv.Count - 1)] | ForEach-Object { [string]$_ }) }

        switch -CaseSensitive ($cmd) {

            # --- active ------------------------------------------------------
            'active' {
                if (-not (Test-FmPfRelayActive $fmHome)) { Exit-FmScript 1 }
                if (-not (Test-FmPfHasRegistration $state) -and -not (Test-FmPfHasEvent $state)) {
                    Exit-FmScript 1
                }
                Exit-FmScript 0
            }

            # --- register ----------------------------------------------------
            'register' {
                $id = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                if ([string]::IsNullOrEmpty($id)) { Write-FmPfUsage; Exit-FmScript 2 }
                $relation = ''; $workHome = ''; $workId = ''; $generation = ''
                $platform = ''; $request = ''
                $i = 1
                while ($i -lt $rest.Count) {
                    switch -CaseSensitive ($rest[$i]) {
                        '--relation' { $i++; $relation = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--work-home' { $i++; $workHome = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--work-id' { $i++; $workId = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--generation' { $i++; $generation = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--platform' { $i++; $platform = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--request' { $i++; $request = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        default { Exit-FmPfDie "unknown argument '$($rest[$i])'" }
                    }
                    $i++
                }

                if (-not (Test-FmPfRelayActive $fmHome)) {
                    Exit-FmPfDie 'this home has not opted into the myfirstmate relay, so it cannot own a public commitment' 1
                }
                & $requireTools

                if (-not (Test-FmPfSlug $id)) { Exit-FmPfDie "unsafe obligation id: $id" }
                if (-not (Test-FmPfSlug $relation)) { Exit-FmPfDie "unsafe relation id: $relation" }
                if (-not (Test-FmPfSlug $workId)) { Exit-FmPfDie "unsafe work id: $workId" }
                if (-not (Test-FmPfHomeId $workHome)) {
                    Exit-FmPfDie "work home must be 'main' or 'secondmate:<stable-id>', got '$workHome'"
                }
                if (-not [regex]::IsMatch($generation, '^[0-9]+\z')) {
                    Exit-FmPfDie "generation must be a positive integer, got '$generation'"
                }
                if ([long]$generation -lt 1) { Exit-FmPfDie 'generation must be >= 1' }

                $lookup = & $obligationJson $id
                if (-not $lookup.Ok) { Exit-FmPfDie 'could not read the backlog through tasks-axi' 1 }
                if ($null -eq $lookup.Payload) {
                    Exit-FmPfDie "no public-followup obligation '$id' in this home's backlog; create it with tasks-axi public-followup add before registering" 1
                }
                $payload = $lookup.Payload

                # The relation must already be bound, so a registration can never
                # describe a binding tasks-axi does not have.
                $bound = $false
                $relations = $null
                if ($payload.Contains('public_followup') -and
                    $payload['public_followup'] -is [System.Collections.IDictionary] -and
                    $payload['public_followup'].Contains('work_relations')) {
                    $relations = $payload['public_followup']['work_relations']
                }
                if ($relations -is [System.Collections.IList]) {
                    foreach ($row in @($relations)) {
                        if ((Get-FmPfField -Record $row -Path 'relation_id') -ceq $relation -and
                            (Get-FmPfField -Record $row -Path 'work_ref.home_id') -ceq $workHome -and
                            (Get-FmPfField -Record $row -Path 'work_ref.task_id') -ceq $workId) {
                            $bound = $true
                            break
                        }
                    }
                }
                if (-not $bound) {
                    Exit-FmPfDie "obligation '$id' has no bound relation '$relation' for $workHome/$workId; run tasks-axi public-followup bind-work first" 1
                }

                if ([string]::IsNullOrEmpty($platform)) {
                    $platform = Get-FmPfField -Record $payload -Path 'public_followup.request.platform'
                }
                if ([string]::IsNullOrEmpty($request)) {
                    $request = Get-FmPfField -Record $payload -Path 'public_followup.request.request_id'
                }
                if (-not [string]::IsNullOrEmpty($request) -and -not (Test-FmPfSlug $request)) {
                    Exit-FmPfDie "unsafe request id: $request"
                }

                foreach ($target in @((Get-FmPfRegistryDir $state), (Get-FmPfEventsDir $state),
                        (Get-FmPfConsumedDir $state), (Get-FmPfRejectedDir $state))) {
                    if ($null -eq (Initialize-FmxPrivateArtifactDir -Directory $target)) {
                        Exit-FmPfDie "could not prepare $target" 1
                    }
                }

                $record = "obligation_id=$id`nrelation_id=$relation`nwork_home=$workHome`n" +
                          "work_id=$workId`ngeneration=$generation`nplatform=$platform`nrequest_id=$request`n"
                if (-not (Publish-FmxPrivateArtifact -Directory (Get-FmPfRegistryDir $state) `
                            -BaseName $id -Mode '600' -Text $record)) {
                    Exit-FmPfDie 'could not write the registration record' 1
                }

                $shownPlatform = if ([string]::IsNullOrEmpty($platform)) { 'unknown' } else { $platform }
                Write-FmOut "registered $id $workHome/$workId generation=$generation platform=$shownPlatform"
                Exit-FmScript 0
            }

            # --- brief -------------------------------------------------------
            'brief' {
                $id = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                if ([string]::IsNullOrEmpty($id)) { Write-FmPfUsage; Exit-FmScript 2 }
                if (-not (Test-FmPfSlug $id)) { Exit-FmPfDie "unsafe obligation id: $id" }
                if (-not (Test-FmPfRelayActive $fmHome)) {
                    Exit-FmPfDie 'the relay is not active for this home' 1
                }
                $file = ConvertTo-FmNativePath "$(Get-FmPfRegistryDir $state)/$id"
                if (-not [System.IO.File]::Exists($file)) {
                    Exit-FmPfDie "no registration for '$id' in this home" 1
                }

                $relation = Get-FmPfRegistryValue $state $id 'relation_id'
                $workHome = Get-FmPfRegistryValue $state $id 'work_home'
                $workId = Get-FmPfRegistryValue $state $id 'work_id'
                $generation = Get-FmPfRegistryValue $state $id 'generation'

                # Paths are printed in the POSIX form the durable records carry,
                # so a brief copied into a worker's instructions reads the same in
                # either world (contract 3).
                $rootText = ConvertTo-FmPosixPath $fmRoot
                $homeText = ConvertTo-FmPosixPath $fmHome
                foreach ($line in @(
                        'When this work reaches its promised terminal outcome, report it as typed data'
                        '(never as a sentence for someone to parse) by running exactly:'
                        ''
                        "  $rootText/bin/fm-public-followup-emit.sh \"
                        "    --home $homeText \"
                        "    --obligation $id \"
                        "    --relation $relation \"
                        "    --source-home $workHome \"
                        "    --work-id $workId \"
                        "    --generation $generation \"
                        '    --outcome <pr-merged|report-ready|local-main|failed> \'
                        '    --deliverable <key>=<value> \'
                        "    --outcome-text '<one bounded public-safe sentence>'"
                        ''
                        'Do not post anything publicly yourself and do not look for the public thread:'
                        'the home above owns the reply.')) {
                    Write-FmOut $line
                }
                Exit-FmScript 0
            }

            # --- consume -----------------------------------------------------
            'consume' {
                & $gateOrExit
                if (-not (Test-FmPfHasEvent $state)) { Exit-FmScript 0 }
                & $requireTools

                $eventsDir = ConvertTo-FmNativePath (Get-FmPfEventsDir $state)
                $consumedDir = Get-FmPfConsumedDir $state
                $rejectedDir = Get-FmPfRejectedDir $state
                if ($null -eq (Initialize-FmxPrivateArtifactDir -Directory $consumedDir)) {
                    Exit-FmPfDie 'could not prepare the consumed-event ledger' 1
                }
                $consumeRc = 0
                $byteMax = [long](Get-FmPfEventByteMax)

                # quarantine one refused event with an inspectable reason so it is
                # never retried in a loop.
                $rejectEvent = {
                    param([string]$File, [string]$EventId, [string]$Reason)
                    if ($null -eq (Initialize-FmxPrivateArtifactDir -Directory $rejectedDir)) {
                        Write-FmOut "rejected ${EventId}: $Reason (quarantine failed; event retained)"
                        return $false
                    }
                    if (-not (Publish-FmxPrivateArtifact -Directory $rejectedDir `
                                -BaseName "$EventId.reason" -Mode '600' -Text ($Reason + "`n"))) {
                        Write-FmOut "rejected ${EventId}: $Reason (quarantine failed; event retained)"
                        return $false
                    }
                    $payloadText = Get-FmFileText $File
                    # `$(cat ...)` then `printf '%s'`: every trailing newline goes
                    # and none is added back.
                    $payloadText = $payloadText.TrimEnd("`n")
                    if (-not (Publish-FmxPrivateArtifact -Directory $rejectedDir `
                                -BaseName "$EventId.json" -Mode '600' -Text $payloadText)) {
                        Write-FmOut "rejected ${EventId}: $Reason (quarantine failed; event retained)"
                        return $false
                    }
                    try {
                        [System.IO.File]::Delete($File)
                    } catch {
                        Write-FmOut "rejected ${EventId}: $Reason (quarantine cleanup failed; event retained)"
                        return $false
                    }
                    Write-FmOut "rejected ${EventId}: $Reason"
                    return $true
                }

                $files = @()
                try {
                    $files = @([System.IO.Directory]::EnumerateFiles($eventsDir, '*'))
                } catch {
                    $files = @()
                }
                $files = @($files | Where-Object { [System.IO.Path]::GetFileName($_).EndsWith('.json') })
                $sorted = [string[]]$files
                [Array]::Sort($sorted, [System.StringComparer]::Ordinal)

                foreach ($file in $sorted) {
                    if (-not [System.IO.File]::Exists($file)) { continue }
                    if (Test-FmSymlink $file) { continue }
                    $name = [System.IO.Path]::GetFileName($file)
                    $eventId = $name.Substring(0, $name.Length - '.json'.Length)

                    if (-not (Test-FmPfSlug $eventId)) {
                        Write-FmOut "rejected ${eventId}: unsafe event filename (event retained)"
                        $consumeRc = 1
                        continue
                    }

                    # Already accepted on an earlier pass (duplicate emit, or a
                    # replay after restart): drop the copy without touching the
                    # state machine.
                    if ([System.IO.File]::Exists(
                            [System.IO.Path]::Combine((ConvertTo-FmNativePath $consumedDir), $eventId))) {
                        try { [System.IO.File]::Delete($file) } catch { $null = $_ }
                        continue
                    }

                    $bytes = 0
                    try { $bytes = [System.IO.FileInfo]::new($file).Length } catch { $bytes = 0 }
                    if ($bytes -gt $byteMax) {
                        if (-not (& $rejectEvent $file $eventId "event exceeds $byteMax bytes")) { $consumeRc = 1 }
                        continue
                    }

                    $payload = $null
                    try { $payload = (Get-FmFileText $file) | ConvertFrom-Json -AsHashtable } catch { $payload = $null }
                    if ($payload -isnot [System.Collections.IDictionary]) {
                        if (-not (& $rejectEvent $file $eventId 'event is not valid JSON')) { $consumeRc = 1 }
                        continue
                    }

                    # The filename, the declared event_id, and the identity tuple
                    # must all agree. A mismatch means the file was hand-edited or
                    # built by something other than fm-public-followup-emit, so it
                    # is refused before tasks-axi sees it.
                    if ((Get-FmPfField -Record $payload -Path 'event_id') -cne $eventId) {
                        if (-not (& $rejectEvent $file $eventId 'declared event_id does not match the filename')) { $consumeRc = 1 }
                        continue
                    }
                    $deliverables = if ($payload.Contains('deliverables') -and $null -ne $payload['deliverables']) {
                        $payload['deliverables']
                    } else {
                        [ordered]@{}
                    }
                    $derived = Get-FmPfEventId `
                        (Get-FmPfField -Record $payload -Path 'obligation_id') `
                        (Get-FmPfField -Record $payload -Path 'relation_id') `
                        (Get-FmPfField -Record $payload -Path 'source_home_id') `
                        (Get-FmPfField -Record $payload -Path 'work_id') `
                        (Get-FmPfField -Record $payload -Path 'generation') `
                        (Get-FmPfField -Record $payload -Path 'outcome_type') `
                        (ConvertTo-FmPfSortedJson -Value $deliverables)
                    if ([string]::IsNullOrEmpty($derived) -or $derived -cne $eventId) {
                        if (-not (& $rejectEvent $file $eventId 'event id does not match its own identity fields')) { $consumeRc = 1 }
                        continue
                    }

                    $obligation = Get-FmPfField -Record $payload -Path 'obligation_id'
                    if (-not (Test-FmPfSlug $obligation)) {
                        if (-not (& $rejectEvent $file $eventId 'unsafe obligation id in event')) { $consumeRc = 1 }
                        continue
                    }

                    # tasks-axi is the authority on source home, work id,
                    # generation, schema, outcome, and deliverables. Anything it
                    # refuses is quarantined verbatim. stderr is captured
                    # separately so a warning can never corrupt the JSON that the
                    # accepted path parses.
                    $applied = & $invokeTasks @('public-followup', 'work-event', $obligation,
                        '--event-file', $file, '--json')
                    if (-not $applied.Ok) {
                        $firstLine = ''
                        foreach ($line in @(($applied.StdErr + $applied.StdOut + "`n").Split("`n"))) {
                            if (-not [regex]::IsMatch($line, '^\s*\z')) { $firstLine = $line; break }
                        }
                        $reasonBytes = Get-FmPfBoundByte 400 (Get-FmPfCleanOutcomeText $firstLine)
                        $reason = [System.Text.Encoding]::UTF8.GetString($reasonBytes).TrimEnd("`n")
                        if ([string]::IsNullOrEmpty($reason)) { $reason = 'tasks-axi refused the event' }
                        if (-not (& $rejectEvent $file $eventId $reason)) { $consumeRc = 1 }
                        continue
                    }

                    if (-not (Publish-FmxPrivateArtifact -Directory $consumedDir -BaseName $eventId `
                                -Mode '600' -Text ("accepted $(Get-FmPfNowRfc3339)`n"))) {
                        Write-FmOut "accepted ${eventId}: consumed ledger could not be recorded; event retained for reconciliation"
                        $consumeRc = 1
                        continue
                    }
                    try {
                        [System.IO.File]::Delete($file)
                    } catch {
                        Write-FmOut "accepted ${eventId}: consumed ledger recorded but event could not be removed; event retained for reconciliation"
                        $consumeRc = 1
                        continue
                    }

                    $result = $null
                    try { $result = $applied.StdOut | ConvertFrom-Json -AsHashtable } catch { $result = $null }
                    if ((Get-FmPfField -Record $result -Path 'task.public_followup.delivery.state') -ceq 'ready') {
                        $request = Get-FmPfField -Record $result -Path 'task.public_followup.request.request_id'
                        $platform = Get-FmPfField -Record $result -Path 'task.public_followup.request.platform'
                        if ([string]::IsNullOrEmpty($request)) { $request = 'unknown' }
                        if ([string]::IsNullOrEmpty($platform)) { $platform = 'unknown' }
                        Write-FmOut "ready $obligation $request $platform"
                    }
                }

                # A fresh event must be able to wake firstmate again, so drop the
                # surfaced signature once the inbox has been worked.
                try {
                    [System.IO.File]::Delete([System.IO.Path]::Combine(
                            (ConvertTo-FmNativePath (Get-FmPfRoot $state)), (Get-FmPfSurfacedBaseName)))
                } catch {
                    $null = $_
                }
                Exit-FmScript $consumeRc
            }

            # --- pending -----------------------------------------------------
            'pending' {
                & $gateOrExit

                $printed = $false
                $listing = $null
                $readable = $false
                if ($null -ne (Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)) {
                    $result = & $invokeTasks @('public-followup', 'list', '--json')
                    if ($result.Ok -and -not [string]::IsNullOrEmpty($result.StdOut)) {
                        $parsed = $null
                        try { $parsed = $result.StdOut | ConvertFrom-Json -AsHashtable } catch { $parsed = $null }
                        if ($parsed -is [System.Collections.IDictionary] -and
                            $parsed.Contains('public_followups') -and
                            $parsed['public_followups'] -is [System.Collections.IList]) {
                            $readable = $true
                            foreach ($row in @($parsed['public_followups'])) {
                                if ($row -isnot [System.Collections.IDictionary] -or
                                    -not ($row.Contains('id') -and $row['id'] -is [string]) -or
                                    -not ($row.Contains('public_followup') -and
                                        $row['public_followup'] -is [System.Collections.IDictionary]) -or
                                    -not ($row.Contains('state') -and $row['state'] -is [string])) {
                                    $readable = $false
                                    break
                                }
                            }
                            if ($readable) { $listing = $parsed }
                        }
                    }
                }

                # An unreadable backlog with registrations present is exactly the
                # silence this whole path exists to prevent, so say so rather than
                # printing nothing.
                if (-not $readable) {
                    if (Test-FmPfHasRegistration $state) {
                        $count = @(Get-FmPfRegistryId $state | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count
                        Write-FmOut ("cannot read this home's public commitments through tasks-axi; {0} registration(s) are still recorded under state/{1}/registry" -f `
                                $count, (Get-FmPfDirName))
                        $printed = $true
                    }
                    if (Test-FmPfHasEvent $state) {
                        Write-FmOut ("unconsumed terminal results are waiting; run {0}/bin/fm-public-followup.sh consume" -f (ConvertTo-FmPosixPath $fmRoot))
                        $printed = $true
                    }
                    if (-not $printed) { Exit-FmScript 0 }
                    Exit-FmScript 0
                }

                foreach ($id in @(Get-FmPfRegistryId $state)) {
                    if ([string]::IsNullOrEmpty($id)) { continue }
                    $payload = $null
                    foreach ($row in @($listing['public_followups'])) {
                        if ([string]$row['id'] -ceq $id) { $payload = $row; break }
                    }
                    if ($null -eq $payload) {
                        # The obligation is gone from the backlog (pruned after
                        # Done): the registration is stale bookkeeping, not
                        # evidence, so drop it.
                        if (-not (& $clearLegacyLink $id)) {
                            Write-FmOut "cannot clear the legacy X link for closed public commitment $id; registration retained for reconciliation"
                            $printed = $true
                            continue
                        }
                        & $removeRegistration $id
                        continue
                    }
                    $delivery = Get-FmPfField -Record $payload -Path 'public_followup.delivery.state'
                    $taskState = Get-FmPfField -Record $payload -Path 'state'
                    if ($taskState -ceq 'done' -or $delivery -ceq 'posted' -or $delivery -ceq 'waived') {
                        if (-not (& $clearLegacyLink $id)) {
                            Write-FmOut "cannot clear the legacy X link for closed public commitment $id; registration retained for reconciliation"
                            $printed = $true
                            continue
                        }
                        & $removeRegistration $id
                        continue
                    }
                    $summary = Get-FmPfCleanOutcomeText (Get-FmPfField -Record $payload `
                            -Path 'public_followup.request.public_safe_summary')
                    $platform = Get-FmPfField -Record $payload -Path 'public_followup.request.platform'
                    $request = Get-FmPfField -Record $payload -Path 'public_followup.request.request_id'
                    if ([string]::IsNullOrEmpty($delivery)) { $delivery = 'unknown' }
                    if ([string]::IsNullOrEmpty($platform)) { $platform = 'unknown' }
                    if ([string]::IsNullOrEmpty($request)) { $request = 'unknown' }
                    Write-FmOut "unresolved $id state=$delivery platform=$platform request=$request summary=$summary"
                    $printed = $true
                }

                # Events that arrived while no agent was present are actionable on
                # their own, so surface them even when every registration
                # currently looks settled.
                if (Test-FmPfHasEvent $state) {
                    Write-FmOut ("unconsumed terminal results are waiting; run {0}/bin/fm-public-followup.sh consume" -f (ConvertTo-FmPosixPath $fmRoot))
                    $printed = $true
                }
                if (-not $printed) { Exit-FmScript 0 }
                Exit-FmScript 0
            }

            # --- deliver -----------------------------------------------------
            'deliver' {
                $id = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                if ([string]::IsNullOrEmpty($id)) { Write-FmPfUsage; Exit-FmScript 2 }
                $textFile = ''
                $i = 1
                while ($i -lt $rest.Count) {
                    switch -CaseSensitive ($rest[$i]) {
                        '--text-file' { $i++; $textFile = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        default { Exit-FmPfDie "unknown argument '$($rest[$i])'" }
                    }
                    $i++
                }

                if (-not (Test-FmPfSlug $id)) { Exit-FmPfDie "unsafe obligation id: $id" }
                if (-not (Test-FmPfRelayActive $fmHome)) {
                    Exit-FmPfDie 'this home has not opted into the myfirstmate relay, so it cannot post a public reply' 1
                }
                & $requireTools

                $lookup = & $obligationJson $id
                if (-not $lookup.Ok) { Exit-FmPfDie 'could not read the backlog through tasks-axi' 1 }
                if ($null -eq $lookup.Payload) {
                    Exit-FmPfDie "no public-followup obligation '$id' in this home's backlog" 1
                }
                $payload = $lookup.Payload

                $delivery = Get-FmPfField -Record $payload -Path 'public_followup.delivery.state'
                $request = Get-FmPfField -Record $payload -Path 'public_followup.request.request_id'
                $platform = Get-FmPfField -Record $payload -Path 'public_followup.request.platform'
                $attempt = Get-FmPfField -Record $payload -Path 'public_followup.delivery.attempt_count'
                if (-not [regex]::IsMatch($attempt, '^[0-9]+\z')) { $attempt = '0' }

                if ($delivery -ceq 'posted' -or $delivery -ceq 'waived') {
                    if (& $registrationValid $id) {
                        if (-not (& $clearLegacyLink $id)) {
                            Exit-FmPfDie "obligation '$id' is already $delivery, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
                        }
                    } else {
                        switch -CaseSensitive (& $legacyLinkStatus $payload) {
                            0 { Exit-FmPfDie "obligation '$id' is already $delivery, but its legacy X link cannot be cleared without a valid registration; reconcile it before any later terminal follow-up" 1 }
                            1 { }
                            default { Exit-FmPfDie "obligation '$id' is already $delivery, but its registration is missing or invalid and the legacy X link cannot be verified; reconcile it before any later terminal follow-up" 1 }
                        }
                    }
                    & $removeRegistration $id
                    Write-FmOut "already delivered $id state=$delivery"
                    Exit-FmScript 0
                } elseif (@('ready', 'retry-due', 'context-blocked', 'unknown', 'partial') -ccontains $delivery) {
                    if (-not (& $registrationValid $id)) {
                        Exit-FmPfDie "public-followup registration for '$id' is missing or invalid; reconcile it before delivery so any legacy X link can be cleared" 1
                    }
                } elseif ($delivery -ceq 'delivery-posting') {
                    Exit-FmPfDie "obligation '$id' is mid-delivery on attempt ${attempt}: a previous post was started and its outcome was never recorded. Confirm whether that post landed, then close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' or reopen it for retry. Posting again here could duplicate the public reply." 1
                } elseif ($delivery -ceq 'pending-work') {
                    Exit-FmPfDie "obligation '$id' is still waiting on its bound work; nothing to deliver yet" 1
                } else {
                    $shown = if ([string]::IsNullOrEmpty($delivery)) { 'unknown' } else { $delivery }
                    Exit-FmPfDie "obligation '$id' is in delivery state '$shown', which is not deliverable" 1
                }

                if ([string]::IsNullOrEmpty($request)) {
                    Exit-FmPfDie "obligation '$id' has no relay request id; its thread binding is unusable" 1
                }

                $text = ''
                if (-not [string]::IsNullOrEmpty($textFile)) {
                    $textNative = ConvertTo-FmNativePath $textFile
                    if (-not [System.IO.File]::Exists($textNative)) {
                        Exit-FmPfDie "reply text file not found: $textFile"
                    }
                    $text = (Get-FmFileText $textNative).TrimEnd("`n")
                } else {
                    # Deterministic default: reuse the accepted terminal event's
                    # bounded public-safe outcome exactly rather than paraphrasing
                    # a landed result.
                    $relations = $null
                    if ($payload.Contains('public_followup') -and
                        $payload['public_followup'] -is [System.Collections.IDictionary] -and
                        $payload['public_followup'].Contains('work_relations')) {
                        $relations = $payload['public_followup']['work_relations']
                    }
                    if ($relations -is [System.Collections.IList]) {
                        foreach ($relation in @($relations)) {
                            if ($relation -isnot [System.Collections.IDictionary]) { continue }
                            if (-not $relation.Contains('accepted_events')) { continue }
                            foreach ($accepted in @($relation['accepted_events'])) {
                                $outcome = Get-FmPfField -Record $accepted -Path 'public_safe_outcome'
                                if (-not [string]::IsNullOrEmpty($outcome)) { $text = $outcome }
                            }
                        }
                    }
                    if ([string]::IsNullOrEmpty($text)) {
                        Exit-FmPfDie "obligation '$id' carries no accepted public-safe outcome to reuse; pass --text-file with the reply you composed" 1
                    }
                }
                if ([string]::IsNullOrEmpty($text)) { Exit-FmPfDie 'the reply text is empty' 2 }

                $textTemp = New-FmPfTempFile -Prefix 'fm-pf-text.'
                if ($null -eq $textTemp) { Exit-FmPfDie 'could not stage the reply text' 1 }
                $receipt = New-FmPfTempFile -Prefix 'fm-pf-postreceipt.'
                if ($null -eq $receipt) { Exit-FmPfDie 'could not stage the post receipt' 1 }
                Set-FmFileText -Path $textTemp -Text $text -NoNewline

                $hash = Get-FmPfSha256 -Path $textTemp
                if ([string]::IsNullOrEmpty($hash)) { Exit-FmPfDie 'could not hash the reply payload' 1 }

                # begin-delivery is what makes a retry safe: it pins the attempt
                # and the exact payload before anything leaves the machine. The
                # attempt is read back rather than assumed, because every later
                # receipt or error must name it exactly.
                $begun = & $invokeTasks @('public-followup', 'begin-delivery', $id,
                    '--payload-hash', $hash, '--json')
                if (-not $begun.Ok) { Exit-FmPfDie "tasks-axi refused to begin delivery for '$id'" 1 }
                $begunRecord = $null
                try { $begunRecord = $begun.StdOut | ConvertFrom-Json -AsHashtable } catch { $begunRecord = $null }
                $attempt = Get-FmPfField -Record $begunRecord -Path 'task.public_followup.delivery.attempt_count'
                if (-not [regex]::IsMatch($attempt, '^[0-9]+\z')) {
                    Exit-FmPfDie "could not read the delivery attempt for '$id' after beginning it; nothing was posted" 1
                }

                $saved = @{}
                foreach ($pair in @(
                        @{ Name = 'FMX_REPLY_PLATFORM'; Value = $platform },
                        @{ Name = 'FM_HOME'; Value = $fmHome })) {
                    $saved[$pair.Name] = [Environment]::GetEnvironmentVariable($pair.Name)
                    [Environment]::SetEnvironmentVariable($pair.Name, $pair.Value)
                }
                $post = $null
                try {
                    $post = Invoke-FmScript -Name 'fm-x-reply' -BinDir $binDir -Arguments @(
                        $request, '--followup', '--receipt-file', $receipt, '--text-file', $textTemp)
                } finally {
                    foreach ($name in $saved.Keys) {
                        [Environment]::SetEnvironmentVariable($name, $saved[$name])
                    }
                }
                if (-not [string]::IsNullOrEmpty([string]$post.StdErr)) {
                    [Console]::Error.Write([string]$post.StdErr)
                }
                $rc = [int]$post.ExitCode

                if ($rc -eq 0) {
                    $receiptRecord = $null
                    try { $receiptRecord = (Get-FmFileText $receipt) | ConvertFrom-Json -AsHashtable } catch { $receiptRecord = $null }
                    $chunks = ''
                    $receiptDryRun = $null
                    if ($receiptRecord -is [System.Collections.IDictionary] -and
                        [string](Get-FmPfField -Record $receiptRecord -Path 'request_id') -ceq $request -and
                        [string](Get-FmPfField -Record $receiptRecord -Path 'endpoint') -ceq 'followup' -and
                        $receiptRecord.Contains('chunks') -and $receiptRecord.Contains('dry_run') -and
                        $receiptRecord['dry_run'] -is [bool]) {
                        $chunkValue = $receiptRecord['chunks']
                        if (($chunkValue -is [int] -or $chunkValue -is [long] -or $chunkValue -is [double]) -and
                            -not ($chunkValue -is [bool]) -and
                            [double]$chunkValue -ge 1 -and
                            [Math]::Floor([double]$chunkValue) -eq [double]$chunkValue) {
                            $chunks = ([long]$chunkValue).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                            $receiptDryRun = [bool]$receiptRecord['dry_run']
                        }
                    }
                    if ([string]::IsNullOrEmpty($chunks)) {
                        Exit-FmPfDie "the public reply for '$id' POSTED but its receipt is missing or invalid; inspect the relay and close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' before any retry" 1
                    }
                    if ($receiptDryRun) {
                        if (-not (& $recordError $id $attempt 'retry-due' 'dry_run_no_post' (Get-FmPfNextAttemptRfc3339 $retryBackoffValue))) {
                            Exit-FmPfDie "dry-run for '$id' did not post and its retryable state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
                        }
                        Exit-FmPfDie "dry-run for '$id' did not post; recorded as retryable and left the obligation open" 1
                    }
                    if (& $recordPosted $id $attempt $request $platform $chunks) {
                        if (-not (& $clearLegacyLink $id)) {
                            Exit-FmPfDie "the public reply for '$id' POSTED and its receipt was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
                        }
                        & $removeRegistration $id
                        Write-FmOut "delivered $id request=$request platform=$platform chunks=$chunks"
                        Exit-FmScript 0
                    }
                    Exit-FmPfDie "the public reply for '$id' POSTED but its receipt could not be recorded; close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' before any retry, or the thread will get a second reply" 1
                }

                if ($rc -eq 8) {
                    if (-not (& $recordError $id $attempt 'context-blocked' 'reply_context_unresolved' '')) {
                        Exit-FmPfDie "the public reply for '$id' was not posted, and its held state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
                    }
                    Exit-FmPfDie "held '$id': the original thread's platform or size budget could not be resolved, so nothing was posted. Retry once the request context is recoverable." 1
                }
                if ($rc -eq 9) {
                    if (-not (& $recordError $id $attempt 'expired-action-required' 'followup_binding_exhausted' '')) {
                        Exit-FmPfDie "the relay rejected '$id', and its expired state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
                    }
                    Exit-FmPfDie "the relay no longer accepts a follow-up for '$id' (window or cap exhausted); nothing was posted and this needs a captain decision" 1
                }
                if (-not (& $recordError $id $attempt 'retry-due' 'relay_post_failed' (Get-FmPfNextAttemptRfc3339 $retryBackoffValue))) {
                    Exit-FmPfDie "posting the public reply for '$id' failed, and its retryable state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
                }
                Exit-FmPfDie "posting the public reply for '$id' failed (exit $rc); recorded as retryable, nothing was delivered" 1
            }

            # --- record-posted -----------------------------------------------
            'record-posted' {
                $id = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                if ([string]::IsNullOrEmpty($id)) { Write-FmPfUsage; Exit-FmScript 2 }
                $attempt = ''
                $chunks = ''
                $i = 1
                while ($i -lt $rest.Count) {
                    switch -CaseSensitive ($rest[$i]) {
                        '--attempt' { $i++; $attempt = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        '--chunks' { $i++; $chunks = if ($i -lt $rest.Count) { $rest[$i] } else { '' } }
                        default { Exit-FmPfDie "unknown argument '$($rest[$i])'" }
                    }
                    $i++
                }
                if (-not (Test-FmPfSlug $id)) { Exit-FmPfDie "unsafe obligation id: $id" }
                if (-not [regex]::IsMatch($attempt, '^[0-9]+\z')) {
                    Exit-FmPfDie '--attempt <n> is required and must be an integer'
                }
                if (-not [regex]::IsMatch($chunks, '^[0-9]+\z') -or [long]$chunks -lt 1) {
                    Exit-FmPfDie '--chunks <n> is required and must be a positive integer'
                }
                if (-not (Test-FmPfRelayActive $fmHome)) {
                    Exit-FmPfDie 'the relay is not active for this home' 1
                }
                if (-not (& $registrationValid $id)) {
                    Exit-FmPfDie "public-followup registration for '$id' is missing or invalid; reconcile it before recording a receipt so any legacy X link can be cleared" 1
                }
                & $requireTools

                $lookup = & $obligationJson $id
                if (-not $lookup.Ok) { Exit-FmPfDie 'could not read the backlog through tasks-axi' 1 }
                if ($null -eq $lookup.Payload) {
                    Exit-FmPfDie "no public-followup obligation '$id' in this home's backlog" 1
                }
                $request = Get-FmPfField -Record $lookup.Payload -Path 'public_followup.request.request_id'
                $platform = Get-FmPfField -Record $lookup.Payload -Path 'public_followup.request.platform'

                if (-not (& $recordPosted $id $attempt $request $platform $chunks)) {
                    Exit-FmPfDie "tasks-axi refused the receipt for '$id' attempt $attempt; the recorded attempt must match exactly" 1
                }
                if (-not (& $clearLegacyLink $id)) {
                    Exit-FmPfDie "the receipt for '$id' was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
                }
                & $removeRegistration $id
                Write-FmOut "recorded $id attempt=$attempt request=$request"
                Exit-FmScript 0
            }

            # --- guard-work ---------------------------------------------------
            'guard-work' {
                $workHome = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                $workId = if ($rest.Count -gt 1) { $rest[1] } else { '' }
                if ([string]::IsNullOrEmpty($workHome) -or [string]::IsNullOrEmpty($workId)) {
                    Write-FmPfUsage
                    Exit-FmScript 2
                }
                if (-not (Test-FmPfRelayActive $fmHome)) { Exit-FmScript 0 }
                if (-not (Test-FmPfHasRegistration $state)) { Exit-FmScript 0 }

                # Reading the registration records needs no tools, so establish
                # whether this work is bound to any commitment before deciding
                # anything else.
                $bound = @(Get-FmPfRegistryIdForWork $state $workHome $workId)
                if ($bound.Count -eq 0) { Exit-FmScript 0 }

                # From here the work IS bound to a public promise, so an unreadable
                # state is a blocking answer, not a pass: cleanup must never
                # proceed on a guess.
                if ($null -eq (Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)) {
                    Write-FmOut "cannot verify the public commitments bound to $workHome/${workId}: jq and tasks-axi are required"
                    Exit-FmScript 3
                }

                $blocked = $false
                foreach ($id in $bound) {
                    if ([string]::IsNullOrEmpty($id)) { continue }
                    $lookup = & $obligationJson $id
                    if (-not $lookup.Ok) {
                        Write-FmOut "cannot read the state of public commitment $id for $workHome/$workId"
                        $blocked = $true
                        continue
                    }
                    # Gone from the backlog entirely (pruned after Done): nothing
                    # left to owe.
                    if ($null -eq $lookup.Payload) { continue }
                    $delivery = Get-FmPfField -Record $lookup.Payload -Path 'public_followup.delivery.state'
                    $taskState = Get-FmPfField -Record $lookup.Payload -Path 'state'
                    if ($taskState -ceq 'done' -or $delivery -ceq 'posted' -or $delivery -ceq 'waived') { continue }
                    if ([string]::IsNullOrEmpty($delivery)) { $delivery = 'unknown' }
                    Write-FmOut "public commitment $id is still $delivery for $workHome/$workId"
                    $blocked = $true
                }
                if ($blocked) { Exit-FmScript 3 }
                Exit-FmScript 0
            }

            # --- retire -------------------------------------------------------
            'retire' {
                $id = if ($rest.Count -gt 0) { $rest[0] } else { '' }
                if ([string]::IsNullOrEmpty($id)) { Write-FmPfUsage; Exit-FmScript 2 }
                $force = $false
                $i = 1
                while ($i -lt $rest.Count) {
                    switch -CaseSensitive ($rest[$i]) {
                        '--force' { $force = $true }
                        default { Exit-FmPfDie "unknown argument '$($rest[$i])'" }
                    }
                    $i++
                }
                if (-not (Test-FmPfSlug $id)) { Exit-FmPfDie "unsafe obligation id: $id" }
                if (-not (Test-FmPfRelayActive $fmHome)) { Exit-FmScript 0 }
                & $requireTools

                $lookup = & $obligationJson $id
                if (-not $lookup.Ok) { Exit-FmPfDie 'could not read the backlog through tasks-axi' 1 }
                if ($null -ne $lookup.Payload) {
                    $delivery = Get-FmPfField -Record $lookup.Payload -Path 'public_followup.delivery.state'
                    $taskState = Get-FmPfField -Record $lookup.Payload -Path 'state'
                    if (-not ($taskState -ceq 'done' -or $delivery -ceq 'posted' -or $delivery -ceq 'waived')) {
                        if (-not $force) {
                            $shown = if ([string]::IsNullOrEmpty($delivery)) { 'unresolved' } else { $delivery }
                            Exit-FmPfDie "obligation '$id' is still $shown; retiring its registration now would hide an open public promise. Deliver it, waive it, or pass --force." 1
                        }
                    }
                }
                if (-not (& $clearLegacyLink $id)) {
                    Exit-FmPfDie "could not clear the legacy X link for '$id'; its registration was retained for reconciliation" 1
                }
                & $removeRegistration $id
                Write-FmOut "retired $id"
                Exit-FmScript 0
            }

            default {
                Write-FmPfUsage
                Exit-FmScript 2
            }
        }
    } finally {
        foreach ($temp in $script:FmPfTempFiles) {
            try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
        }
    }
}
