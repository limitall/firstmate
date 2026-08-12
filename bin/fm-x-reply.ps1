# Post firstmate's composed answer back to the relay for a pending X-mode mention.
#
# Twin: bin/fm-x-reply.sh
#
# Usage: fm-x-reply.ps1 <request_id> [--image <path>] <text>
#        fm-x-reply.ps1 <request_id> [--image <path>] --text-file <path>
#        fm-x-reply.ps1 <request_id> [--image <path>] -
#        fm-x-reply.ps1 <request_id> --followup [--image <path>] ...
#        fm-x-reply.ps1 <request_id> ... --receipt-file <path>
#
# --receipt-file <path> writes {request_id, endpoint, chunks, dry_run} to <path>
# after the reply lands, so a caller that must record HOW MANY messages were
# posted (bin/fm-public-followup, building a typed delivery receipt) does not
# have to re-derive the split. Omitted by default and never written on failure,
# so stdout, exit codes, and every existing caller stay unchanged.
#
# The --text-file / stdin forms exist so a caller never has to inline reply text
# (which may be influenced by a public mention) into a shell command, where shell
# expansion or quote-breakage could bite. fmx-respond uses them; the positional
# <text> form is kept for back-compat and tests.
#
# Optional --image <path> attaches one local image file to the answer or followup
# POST body as {media_type,data_base64}. Supported extension mapping includes
# PNG, JPEG, GIF, WebP, BMP, and TIFF. If long text becomes a thread, the relay
# attaches that image to the first/opener message only.
#
# Two endpoints, one client. By default the reply is the single answer to a
# mention, POSTed to $RELAY/connector/answer. With --followup it is instead one
# of up to three later "here's where things stand" replies for a mention that
# spawned real work, POSTed to $RELAY/connector/followup.
#
# On success it echoes ONLY that request_id; on a non-2xx (or transport failure)
# it exits non-zero so the caller knows the post did not land. A follow-up 409 is
# always mapped to exit code 9 so fm-x-followup can tell "exhausted binding"
# apart from a transient post failure worth retrying.
#
# FAIL-SAFE: if a --followup reply's platform/budget cannot be authoritatively
# resolved, this REFUSES with exit 8 (distinct from the 409 exit 9) rather than
# posting with a locally defaulted budget - firstmate holds and retries it. Exit
# 8 is a RETRYABLE HOLD, not a failure, and fm-x-followup depends on that
# meaning.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), the reply is NOT posted.
# Instead the would-be POST body is recorded to
# state/x-outbox/<request_id>.json and a "DRY RUN" summary is printed to stderr;
# stdout still echoes the request_id and the exit is 0. Dry-run needs neither a
# token nor the relay.
#
# ---------------------------------------------------------------------------
# WHAT DIFFERS FROM THE BASH TWIN, AND WHY
#
#   NO jq PRESENCE CHECK. The bash twin refuses with "jq not found" because it
#   builds every payload with jq. Payload construction lives in fm-x-lib.psm1
#   here and needs no external tool, so demanding jq would refuse a reply this
#   twin can compose (docs/powershell-port.md: jq is gone).
#
#   NO param() BLOCK. The bash CLI takes bare positional words and one of them is
#   `-h`; a declared parameter block would make PowerShell try to BIND it and
#   fail before the script runs. Every argument lands in $args verbatim instead.
#
#   THE CONTEXT-RESOLUTION FAILURE BRANCH IS UNREACHABLE. The bash twin exits 1
#   when fmx_resolve_reply_context returns non-zero; Resolve-FmxReplyContext
#   always answers (an unresolved axis comes back empty), so the fail-safe below
#   - not that branch - is what stops an unresolved follow-up.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# fm-common FIRST, and never -Force from inside a nested import: see
# docs/powershell-port.md, "Never -Force a NESTED module import".
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force

$fmArgv = @($args)

function Write-FmxReplyUsage {
    [CmdletBinding()]
    param()
    Write-FmErr 'usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] [--receipt-file <path>] <text> | ... --text-file <path> | ... -'
}

function Write-FmxReplyHelp {
    [CmdletBinding()]
    param()
    $lines = @(
        'usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] [--receipt-file <path>] <text>'
        '       fm-x-reply.sh <request_id> [--followup] [--image <path>] [--receipt-file <path>] --text-file <path>'
        '       fm-x-reply.sh <request_id> [--followup] [--image <path>] [--receipt-file <path>] -'
        ''
        'Post a public-safe X-mode answer to the relay, or a completion follow-up with --followup.'
        ''
        'Options:'
        '  --followup       POST to /connector/followup instead of /connector/answer.'
        '  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet or message.'
        '  --receipt-file <path>'
        '                   After a successful reply, write {request_id, endpoint, chunks, dry_run} to <path>.'
        '  --text-file <path>'
        '                   Read reply text from a file instead of the command line.'
        '  -                Read reply text from stdin.'
        '  --help           Show this help.'
    )
    foreach ($line in $lines) { Write-FmOut $line }
}

# write_reply_receipt: record what this reply actually sent, for a caller that
# has to build a typed delivery receipt. Only ever called on success. A write
# failure is reported but never changes the exit status: the reply already
# landed, and claiming otherwise would invite a duplicate post.
function Write-FmxReplyReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][int]$Chunks,
        [Parameter(Mandatory)][bool]$DryRun
    )
    if ([string]::IsNullOrEmpty($Path)) { return }
    $record = [ordered]@{
        request_id = $RequestId
        endpoint   = $Endpoint
        chunks     = $Chunks
        dry_run    = $DryRun
    }
    try {
        # PRETTY, not -Compress: the bash twin writes this with `jq -n`, whose
        # default two-space rendering is what bin/fm-public-followup reads back
        # and what the differential harness compares byte-for-byte.
        Set-FmFileText -Path $Path -Text ((ConvertTo-Json -InputObject $record -Depth 20) + "`n")
    } catch {
        Write-FmErr "fm-x-reply: warning: posted but could not write the receipt to $Path"
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State

    if ($fmArgv.Count -gt 0 -and ($fmArgv[0] -ceq '--help' -or $fmArgv[0] -ceq '-h')) {
        Write-FmxReplyHelp
        Exit-FmScript 0
    }

    $req = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    if ([string]::IsNullOrEmpty($req)) {
        Write-FmxReplyUsage
        Exit-FmScript 2
    }

    # --followup selects the relay's /connector/followup endpoint instead of
    # /connector/answer; it may appear anywhere after the request_id, so strip it
    # out along with --image and --receipt-file and process the remaining args
    # (the text source) exactly as the answer path always has.
    $followup = $false
    $imagePath = ''
    $receiptFile = ''
    $rest = [System.Collections.Generic.List[string]]::new()
    $i = 1
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        switch -CaseSensitive ($arg) {
            '--followup' { $followup = $true }
            '--image' {
                $i++
                if ($i -ge $fmArgv.Count -or [string]::IsNullOrEmpty([string]$fmArgv[$i])) {
                    Write-FmErr 'fm-x-reply: missing --image path'
                    Write-FmxReplyUsage
                    Exit-FmScript 2
                }
                $imagePath = [string]$fmArgv[$i]
            }
            '--receipt-file' {
                $i++
                if ($i -ge $fmArgv.Count -or [string]::IsNullOrEmpty([string]$fmArgv[$i])) {
                    Write-FmErr 'fm-x-reply: missing --receipt-file path'
                    Write-FmxReplyUsage
                    Exit-FmScript 2
                }
                $receiptFile = [string]$fmArgv[$i]
            }
            default { $rest.Add($arg) }
        }
        $i++
    }
    if ($rest.Count -lt 1) {
        Write-FmxReplyUsage
        Exit-FmScript 2
    }

    $text = ''
    if ($rest[0] -ceq '--text-file') {
        if ($rest.Count -lt 2) {
            Write-FmErr 'usage: fm-x-reply.sh <request_id> [--followup] [--image <path>] --text-file <path>'
            Exit-FmScript 2
        }
        $textPath = ConvertTo-FmNativePath $rest[1]
        if (-not [System.IO.File]::Exists($textPath)) {
            Write-FmErr "fm-x-reply: cannot read text file: $($rest[1])"
            Exit-FmScript 1
        }
        try {
            $text = [System.IO.File]::ReadAllText($textPath)
        } catch {
            Write-FmErr "fm-x-reply: cannot read text file: $($rest[1])"
            Exit-FmScript 1
        }
        # `$(cat ...)` strips every trailing newline.
        $text = $text.TrimEnd("`n")
    } elseif ($rest[0] -ceq '-') {
        # `$(cat)`: every trailing newline goes, a CR does not - it is an
        # ordinary byte to the shell and must stay one here.
        $text = [Console]::In.ReadToEnd()
        if ($null -eq $text) { $text = '' }
        $text = $text.TrimEnd("`n")
    } else {
        $text = $rest[0]
    }
    if ([string]::IsNullOrEmpty($text)) {
        Write-FmErr 'fm-x-reply: empty reply text'
        Exit-FmScript 2
    }

    # The endpoint is the only behavioral difference between an answer and a
    # follow-up; everything below (split, payload, dry-run, post) is shared.
    $endpoint = if ($followup) { 'followup' } else { 'answer' }

    $config = Get-FmxConfig -HomePath $ctx.Home

    # The request_id becomes a filename (inbox/outbox record), so never trust it
    # into a path even though the relay issues it.
    if ($req.StartsWith('.', [System.StringComparison]::Ordinal) -or -not [regex]::IsMatch($req, '^[A-Za-z0-9._-]+\z')) {
        Write-FmErr "fm-x-reply: unsafe request_id: $req"
        Exit-FmScript 2
    }

    # Resolve the reply platform + split budget. An explicit env override wins per
    # axis (fm-x-followup passes recorded task-link context this way); otherwise
    # resolve through the durable per-request context registry, then the
    # still-present inbox payload, then - for a follow-up posted live by
    # request_id after the inbox has been drained - an AUTHORITATIVE relay lookup.
    # The relay step is confined to the follow-up path so the answer path and
    # every dry-run stay network-free (fm-x-lib owns the resolution-order
    # contract).
    $envPlatform = Get-FmEnv 'FMX_REPLY_PLATFORM'
    $envMax = Get-FmEnv 'FMX_REPLY_MAX_CHARS'
    $allowRelay = $false
    $reqPlatform = ''
    $reqExplicitMax = ''
    if (-not [string]::IsNullOrEmpty($envPlatform) -and -not [string]::IsNullOrEmpty($envMax)) {
        $reqPlatform = $envPlatform
        $reqExplicitMax = $envMax
    } else {
        if ($followup -and -not $config.DryRun -and -not [string]::IsNullOrEmpty([string]$config.Token)) {
            $allowRelay = $true
        }
        $resolved = Resolve-FmxReplyContext -State $state -RequestId $req -AllowRelay:$allowRelay
        $record = $null
        try { $record = $resolved | ConvertFrom-Json -AsHashtable } catch { $record = $null }
        $ctxPlatform = ''
        $ctxMax = ''
        if ($record -is [System.Collections.IDictionary]) {
            if ($record.Contains('platform') -and $null -ne $record['platform']) {
                $ctxPlatform = [string]$record['platform']
            }
            if ($record.Contains('reply_max_chars') -and $null -ne $record['reply_max_chars']) {
                $ctxMax = [string]$record['reply_max_chars']
            }
        }
        $reqPlatform = if (-not [string]::IsNullOrEmpty($envPlatform)) { $envPlatform } else { $ctxPlatform }
        $reqExplicitMax = if (-not [string]::IsNullOrEmpty($envMax)) { $envMax } else { $ctxMax }
    }
    # Spelled as an if-chain rather than a switch: PowerShell's switch does not
    # reliably match an empty-string case, and '' is a legitimate value here
    # (fm-x-lib.psm1's Get-FmxConfig records the same trap).
    if ($reqPlatform -ceq 'twitter') {
        $reqPlatform = 'x'
    } elseif ($reqPlatform -cne 'discord' -and $reqPlatform -cne 'x' -and $reqPlatform -cne '') {
        $reqPlatform = ''
    }
    if (-not [regex]::IsMatch($reqExplicitMax, '^[0-9]+\z')) { $reqExplicitMax = '' }

    # Was the platform/budget authoritatively resolved by any source (override,
    # registry, inbox, or relay)? Drives the follow-up fail-safe below.
    $contextResolved = (-not [string]::IsNullOrEmpty($reqPlatform)) -and
                       (-not [string]::IsNullOrEmpty($reqExplicitMax))

    if ($followup -and -not $contextResolved) {
        $relayNote = if ($allowRelay) { ', and the relay did not supply the missing value by request_id' } else { '' }
        Write-FmErr ("fm-x-reply: refusing follow-up for {0}: could not authoritatively determine both the reply platform and explicit budget (local per-request context was incomplete{1}). Hold and retry once both values are recoverable." -f $req, $relayNote)
        Exit-FmScript 8
    }
    $replyMax = Get-FmxReplyLimit -Platform $reqPlatform -Explicit $reqExplicitMax

    $tempRoot = ConvertTo-FmNativePath (Get-FmEnv 'TMPDIR' ([System.IO.Path]::GetTempPath()))
    $temps = [System.Collections.Generic.List[string]]::new()
    $newTemp = {
        $path = [System.IO.Path]::Combine($tempRoot, 'fm-x-reply.' + [System.IO.Path]::GetRandomFileName())
        Set-FmFileText -Path $path -Text '' -NoNewline
        $temps.Add($path)
        $path
    }

    try {
        $imagePayloadFile = ''
        $imagePreview = ''
        if (-not [string]::IsNullOrEmpty($imagePath)) {
            try {
                $imagePayloadFile = & $newTemp
            } catch {
                Write-FmErr 'fm-x-reply: cannot create image payload temp file'
                Exit-FmScript 1
            }
            $imagePreview = New-FmxImagePayloadFile -Path $imagePath -Client 'fm-x-reply' `
                -PayloadPath $imagePayloadFile
            if ($null -eq $imagePreview) { Exit-FmScript 1 }
            try {
                $null = $imagePreview | ConvertFrom-Json -AsHashtable
            } catch {
                Write-FmErr 'fm-x-reply: failed to build image preview'
                Exit-FmScript 1
            }
        }

        # Auto-split a long reply into a numbered thread using the target
        # platform's per-message budget. A reply that fits in one message stays
        # single and unnumbered.
        $chunks = @(Split-FmxThread -Text $text -Limit ([int]$replyMax) -Cap ([int]$config.ThreadMax))
        $count = $chunks.Count
        if ($count -le 0) {
            Write-FmErr 'fm-x-reply: empty reply text'
            Exit-FmScript 2
        }

        try {
            $payloadFile = & $newTemp
        } catch {
            Write-FmErr 'fm-x-reply: cannot create request payload temp file'
            Exit-FmScript 1
        }
        $payloadJson = if ([string]::IsNullOrEmpty($imagePayloadFile)) {
            Get-FmxReplyPayloadJson -RequestId $req -Chunk $chunks -Count $count
        } else {
            Get-FmxReplyPayloadJson -RequestId $req -Chunk $chunks -Count $count `
                -ImagePayloadPath $imagePayloadFile
        }
        if ([string]::IsNullOrEmpty($payloadJson)) {
            Write-FmErr 'fm-x-reply: failed to build request payload'
            Exit-FmScript 1
        }
        Set-FmFileText -Path $payloadFile -Text ($payloadJson + "`n") -NoNewline

        # Preview / dry-run: surface what we WOULD post and stop, without auth or
        # network.
        if ($config.DryRun) {
            $outbox = "$state/x-outbox"
            $record = Get-FmxReplyOutboxJson -RequestId $req -Chunk $chunks -Count $count `
                -Followup $followup -ImagePreviewJson $imagePreview
            if ([string]::IsNullOrEmpty($record)) {
                Write-FmErr 'fm-x-reply: failed to build dry-run outbox record'
                Exit-FmScript 1
            }
            if (-not (Publish-FmxPrivateArtifact -Directory $outbox -BaseName "$req.json" `
                        -Mode '600' -Text ($record + "`n"))) {
                Write-FmErr "fm-x-reply: cannot write dry-run outbox: $outbox/$req.json"
                Exit-FmScript 1
            }
            if ($count -le 1) {
                Write-FmErr ("fm-x-reply: DRY RUN - would POST to {0}/connector/{1} (recorded: state/x-outbox/{2}.json): {3}" -f `
                        $config.Relay, $endpoint, $req, $chunks[0])
            } else {
                Write-FmErr ("fm-x-reply: DRY RUN - would POST a {0}-tweet thread to {1}/connector/{2} (recorded: state/x-outbox/{3}.json):" -f `
                        $count, $config.Relay, $endpoint, $req)
                foreach ($chunk in $chunks) { Write-FmErr "  $chunk" }
            }
            Write-FmxReplyReceipt -Path $receiptFile -RequestId $req -Endpoint $endpoint `
                -Chunks $count -DryRun $true
            Write-FmOut $req
            Exit-FmScript 0
        }

        if ([string]::IsNullOrEmpty([string]$config.Token)) {
            Write-FmErr 'fm-x-reply: X mode not configured (no FMX_PAIRING_TOKEN)'
            Exit-FmScript 1
        }
        try {
            $responseFile = & $newTemp
        } catch {
            Write-FmErr 'fm-x-reply: cannot create relay response temp file'
            Exit-FmScript 1
        }

        $post = Send-FmxJson -Endpoint $endpoint -PayloadPath $payloadFile -BodyPath $responseFile
        switch -CaseSensitive ([int]$post.ExitCode) {
            0 { }
            127 { Write-FmErr 'fm-x-reply: curl not found'; Exit-FmScript 1 }
            3 { Write-FmErr 'fm-x-reply: invalid FMX_PAIRING_TOKEN'; Exit-FmScript 1 }
            default { Write-FmErr 'fm-x-reply: request to relay failed'; Exit-FmScript 1 }
        }

        $code = [string]$post.Code
        if ([regex]::IsMatch($code, '^2[0-9][0-9]\z')) {
            if (-not $followup) {
                if (-not (Set-FmxContextRegistryRecord -State $state -RequestId $req `
                            -Platform $reqPlatform -ReplyMax $reqExplicitMax -Refresh)) {
                    Write-FmErr "fm-x-reply: warning: could not retain reply context for $req"
                }
            }
            Write-FmxReplyReceipt -Path $receiptFile -RequestId $req -Endpoint $endpoint `
                -Chunks $count -DryRun $false
            Write-FmOut $req
            Exit-FmScript 0
        }

        if ($code -ceq '409' -and $followup) {
            $body = Get-FmFileText $responseFile
            $confirmed = $false
            if ($body.Length -gt 0) {
                $parsed = $null
                try { $parsed = $body | ConvertFrom-Json -AsHashtable } catch { $parsed = $null }
                if ($parsed -is [System.Collections.IDictionary] -and $parsed.Contains('error') -and
                    [string]$parsed['error'] -ceq 'followup_unavailable') {
                    $confirmed = $true
                } elseif ($body.Contains('followup_unavailable')) {
                    $confirmed = $true
                }
            }
            if ($confirmed) {
                Write-FmErr 'fm-x-reply: relay rejected the follow-up (confirmed followup_unavailable marker): HTTP 409'
            } else {
                Write-FmErr 'fm-x-reply: relay rejected the follow-up (HTTP 409 cap/window exhaustion; marker absent)'
            }
            Exit-FmScript 9
        }

        Write-FmErr "fm-x-reply: relay returned HTTP $code"
        Exit-FmScript 1
    } finally {
        # The bash twin's EXIT trap over TMP_FILES.
        foreach ($temp in $temps) {
            try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
        }
    }
}
