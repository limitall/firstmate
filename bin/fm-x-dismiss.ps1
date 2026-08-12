# Dismiss a pending X-mode mention at the relay WITHOUT replying to it.
#
# Twin: bin/fm-x-dismiss.sh
#
# Usage: fm-x-dismiss.ps1 <request_id>
#
# When firstmate decides NOT to reply to a mention (a pure acknowledgment, or any
# mention it judges not worth a reply), clearing only the local inbox file is not
# enough: the relay keeps re-offering that request on every poll until it times
# out to a polite "offline" auto-reply. Dismiss tells the relay to drop the
# request outright - it posts nothing and stops re-offering it - so a skipped
# mention causes no re-offer churn and no offline auto-reply.
#
# POSTs {"request_id":"<id>"} (no text - a dismiss has no body) to
# $RELAY/connector/dismiss with the bearer token. On success (2xx) it echoes ONLY
# the request_id and clears the request's durable per-request reply context
# (state/x-context/<id>.json; a dismissed mention never gets a follow-up); on a
# non-2xx (or transport failure) it exits non-zero so the caller knows the
# dismiss did not land and can fall back to leaving the inbox file for a later
# pass.
#
# Live post config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN
# (required), FMX_RELAY_URL (default https://myfirstmate.io). Auth:
# Authorization: Bearer <token>.
#
# Preview / dry-run: with FMX_DRY_RUN set (truthy), nothing is posted. Instead the
# would-be POST body ({request_id}) is recorded to state/x-outbox/<request_id>.json
# with an "endpoint":"dismiss" marker so the preview is self-describing (the live
# POST body stays {request_id}), a "DRY RUN" summary is printed to stderr, and
# stdout still echoes the request_id with exit 0. Dry-run needs neither a token
# nor the relay.
#
# ---------------------------------------------------------------------------
# WHAT DIFFERS FROM THE BASH TWIN
#
#   NO jq PRESENCE CHECK: the one-key payload is composed in-process, so jq is
#   not a dependency here (docs/powershell-port.md).
#
#   curl IS RESOLVED THROUGH Get-Command before it is run. Windows CreateProcess
#   appends only ".exe" to a bare name, so handing it "curl" would skip a curl
#   published under any other PATHEXT extension that `command -v curl` accepts.
#   The response body goes to NUL rather than /dev/null for the same reason:
#   these are the platform's spellings of the same two things.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State

    $req = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    if ([string]::IsNullOrEmpty($req) -or $fmArgv.Count -gt 1) {
        Write-FmErr 'usage: fm-x-dismiss.sh <request_id>'
        Exit-FmScript 2
    }

    $config = Get-FmxConfig -HomePath $ctx.Home

    # The request_id becomes a filename (inbox/outbox record), so never trust it
    # into a path even though the relay issues it.
    if ($req.StartsWith('.', [System.StringComparison]::Ordinal) -or -not [regex]::IsMatch($req, '^[A-Za-z0-9._-]+\z')) {
        Write-FmErr "fm-x-dismiss: unsafe request_id: $req"
        Exit-FmScript 2
    }

    # This is exactly what would be POSTed (and, in dry-run, exactly what we
    # record/preview): a dismiss carries only {request_id}.
    $payload = ConvertTo-Json -InputObject ([ordered]@{ request_id = $req }) -Depth 20 -Compress

    # Preview / dry-run: surface what we WOULD post and stop, without auth or
    # network.
    if ($config.DryRun) {
        $outbox = "$state/x-outbox"
        # The recorded body carries an "endpoint":"dismiss" marker so an outbox
        # record is self-describing (the live POST body stays exactly
        # {request_id}). jq's `. + {endpoint:"dismiss"}` appends the new key
        # after the existing ones, which is what the ordered map reproduces.
        $record = ConvertTo-Json -Depth 20 -Compress -InputObject ([ordered]@{
                request_id = $req
                endpoint   = 'dismiss'
            })
        if (-not (Publish-FmxPrivateArtifact -Directory $outbox -BaseName "$req.json" `
                    -Mode '600' -Text ($record + "`n"))) {
            Write-FmErr "fm-x-dismiss: cannot write dry-run outbox: $outbox/$req.json"
            Exit-FmScript 1
        }
        # A dismissed mention will never get a follow-up, so drop its durable
        # per-request reply context too. Best-effort; a no-op when none was
        # recorded.
        Clear-FmxContextRegistryRecord -State $state -RequestId $req
        Write-FmErr ("fm-x-dismiss: DRY RUN - would POST to {0}/connector/dismiss (recorded: state/x-outbox/{1}.json)" -f `
                $config.Relay, $req)
        Write-FmOut $req
        Exit-FmScript 0
    }

    if ([string]::IsNullOrEmpty([string]$config.Token)) {
        Write-FmErr 'fm-x-dismiss: X mode not configured (no FMX_PAIRING_TOKEN)'
        Exit-FmScript 1
    }
    $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $curl) {
        Write-FmErr 'fm-x-dismiss: curl not found'
        Exit-FmScript 1
    }
    $headerFile = New-FmxAuthHeaderFile
    if ($null -eq $headerFile) {
        Write-FmErr 'fm-x-dismiss: invalid FMX_PAIRING_TOKEN'
        Exit-FmScript 1
    }

    try {
        $sink = if (Test-FmWindows) { 'NUL' } else { '/dev/null' }
        $post = Invoke-FmTool -FilePath $curl.Source -Arguments @(
            '-m', '10', '-s', '-o', $sink, '-w', '%{http_code}',
            '-X', 'POST',
            '-H', "@$headerFile",
            '-H', 'Content-Type: application/json',
            '--data', $payload,
            "$($config.Relay)/connector/dismiss")
        if (-not $post.Ok) {
            Write-FmErr 'fm-x-dismiss: request to relay failed'
            Exit-FmScript 1
        }
        $code = $post.StdOut.Trim()
        if ([regex]::IsMatch($code, '^2[0-9][0-9]\z')) {
            # Dropped at the relay: no follow-up will come, so clear the durable
            # per-request reply context too (best-effort, no-op when none was
            # recorded).
            Clear-FmxContextRegistryRecord -State $state -RequestId $req
            Write-FmOut $req
            Exit-FmScript 0
        }
        Write-FmErr "fm-x-dismiss: relay returned HTTP $code"
        Exit-FmScript 1
    } finally {
        # The bash twin's EXIT trap on the header file.
        try { [System.IO.File]::Delete((ConvertTo-FmNativePath $headerFile)) } catch { $null = $_ }
    }
}
