# One short-poll of the relay connector for a pending X-mode mention.
#
# Twin: bin/fm-x-poll.sh
#
# Inert by default: a HARD no-op (exit 0, no output) unless X mode is configured
# via a non-empty FMX_PAIRING_TOKEN (from the home's .env or the environment).
# The watcher invokes this trusted repository script directly only after
# state/x-watch.check.sh matches the expected byte-static identity shim.
# Its contract is "output => wake firstmate, silence => keep sleeping", so the
# no-op keeps the watcher behaving exactly as today until a user opts in.
#
# Behavior when X mode is on:
#   HTTP 204 / empty / missing text              -> print nothing, exit 0 (no wake)
#   auth/config errors                           -> print one rate-limited diagnostic
#   a newly offered mention with non-empty text -> stash the full object to
#       state/x-inbox/<request_id>.json, record the durable per-request reply
#       context to state/x-context/<request_id>.json (best-effort), atomically
#       claim state/x-context/<request_id>.offered.json, and print one compact
#       line "x-mention <request_id>" (which becomes the watcher wake payload)
#   an already offered request_id                -> print nothing, exit 0
#   a new set of unreconciled public-followup terminal results -> print one
#       "public-followup ..." line BEFORE the relay call, so a promised final
#       reply is surfaced through this same wake path
#
# The public-followup line rides here rather than on a new poll of its own: this
# check only exists in a home that opted into the relay, and it is an O(1)
# directory presence test plus a signature compare, with no tasks-axi call and no
# backlog scan. A home with no pending terminal results pays nothing for it.
# The full object is stashed verbatim, so any conversation context the relay
# includes (in_reply_to: {author_handle, text}, null for a fresh mention) is
# preserved for fmx-respond to handle follow-ups with continuity. The durable
# context record lets a delayed follow-up recover the ORIGINAL platform/budget
# even after this inbox file is drained.
#
# Config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN (required),
# FMX_RELAY_URL (default https://myfirstmate.io). Auth: Authorization: Bearer
# <token>.
#
# ---------------------------------------------------------------------------
# THREE MECHANICS THAT DIFFER FROM THE BASH TWIN, EACH DELIBERATE
#
#   NO jq PRESENCE CHECK. The bash twin refuses with "missing jq" because it
#   parses the relay payload with jq. This twin parses with ConvertFrom-Json
#   in-process, so jq is not a dependency and demanding it would refuse a poll
#   this script can serve (docs/powershell-port.md: jq is gone). The "missing
#   curl" refusal is preserved exactly, because curl IS still the transport.
#
#   curl IS RESOLVED THROUGH Get-Command, NOT HANDED TO Process.Start AS A BARE
#   NAME. Windows CreateProcess appends only ".exe" to an extensionless name, so
#   a bare "curl" would skip anything published under another PATHEXT extension
#   that `command -v curl` finds - and, in a test, would reach the real system
#   curl instead of the fake on PATH. Same resolution bin/fm-pr-check.ps1 uses.
#
#   THE INBOX STASH REPRODUCES `jq '.'`, NOT a compact record. The bash twin
#   re-renders the relay body with jq's default pretty printer before publishing
#   it; ConvertTo-Json -Depth 20 emits the same two-space shape (verified on this
#   host, including that PowerShell 7 does NOT HTML-escape < > &), so a stashed
#   mention is byte-identical across the two worlds.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# fm-common FIRST and only here with -Force: fm-x-lib and fm-public-followup-lib
# both import it as a NESTED module, and a -Force import of a nested module is
# GLOBAL removal plus re-import - it would strip the commands this script already
# holds (docs/powershell-port.md, "Never -Force a NESTED module import").
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1') -Force

# jq's `.key // empty` followed by `tostring`, for the two payload fields this
# script reads. Kept local rather than exported from fm-x-lib because it is a
# rendering convenience for THIS script's two reads, not a protocol rule.
function Get-FmxPollField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Record,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Record) { return '' }
    if ($Record -isnot [System.Collections.IDictionary]) { return '' }
    if (-not $Record.Contains($Name)) { return '' }
    $value = $Record[$Name]
    # `// empty` treats null AND false as absent.
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { '' }) }
    if ($value -is [string]) { return $value }
    if ($value -is [double] -or $value -is [decimal]) {
        $d = [double]$value
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e18) {
            return ([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$value
}

# emit_error_once: one diagnostic per distinct message, so a persistent
# misconfiguration wakes firstmate once rather than every cycle.
function Write-FmxPollErrorOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Message
    )
    if ((Test-FmxPrivateArtifactFile -Directory $State -BaseName $BaseName -Mode '600') -and
        ((Get-FmFileText "$State/$BaseName").TrimEnd("`n") -ceq $Message)) {
        return
    }
    # A publish failure is swallowed exactly as the bash twin's `|| true` does:
    # the diagnostic still reaches firstmate, it just is not deduplicated.
    $null = Publish-FmxPrivateArtifact -Directory $State -BaseName $BaseName -Mode '600' `
        -Text ($Message + "`n")
    Write-FmOut "x-mode-error $Message"
}

# clear_error: only ever through a directory that still passes its own gate, so
# a removal can never reach outside state/.
function Clear-FmxPollError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$BaseName
    )
    if ($null -eq (Get-FmxPrivateArtifactDirDevice -Directory $State)) { return }
    try {
        [System.IO.File]::Delete([System.IO.Path]::Combine((ConvertTo-FmNativePath $State), $BaseName))
    } catch {
        $null = $_
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State
    $errorBase = 'x-poll.error'
    $claimErrorBase = 'x-poll.claim-error'

    $config = Get-FmxConfig -HomePath $ctx.Home
    # Hard no-op when X mode is off: this is what keeps the check shim inert.
    if ([string]::IsNullOrEmpty([string]$config.Token)) { Exit-FmScript 0 }

    # Unreconciled terminal results for a public commitment are actionable even
    # when the relay has no new mention, and they outlive any session, so surface
    # them first. The signature compare keeps this to one wake per new result set
    # instead of one per cycle; bin/fm-public-followup consume clears it.
    if (Test-FmPfHasEvent $state) {
        $pfRoot = Get-FmPfRoot $state
        $pfSurfaced = Get-FmPfSurfacedBaseName
        $pfSig = Get-FmPfEventsSignature $state
        if (-not [string]::IsNullOrEmpty($pfSig) -and
            (Get-FmFileText "$pfRoot/$pfSurfaced").TrimEnd("`n") -cne $pfSig) {
            if (Publish-FmxPrivateArtifact -Directory $pfRoot -BaseName $pfSurfaced -Mode '600' `
                    -Text ($pfSig + "`n")) {
                Write-FmOut 'public-followup terminal results are waiting to be reconciled'
            }
        }
    }

    $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $curl) {
        Write-FmxPollErrorOnce -State $state -BaseName $errorBase -Message 'missing curl'
        Exit-FmScript 0
    }

    Clear-FmxExpiredContextRegistryRecord -State $state

    $tempRoot = ConvertTo-FmNativePath (Get-FmEnv 'TMPDIR' ([System.IO.Path]::GetTempPath()))
    $bodyFile = [System.IO.Path]::Combine($tempRoot, 'fm-x-poll.' + [System.IO.Path]::GetRandomFileName())
    $headerFile = $null
    try {
        try {
            Set-FmFileText -Path $bodyFile -Text '' -NoNewline
        } catch {
            # `mktemp ... || exit 0`: an unusable temp directory is not this
            # script's problem to report, it just means no wake this cycle.
            Exit-FmScript 0
        }

        $headerFile = New-FmxAuthHeaderFile
        if ($null -eq $headerFile) {
            Write-FmxPollErrorOnce -State $state -BaseName $errorBase -Message 'invalid token'
            Exit-FmScript 0
        }

        # Short, bounded poll: a failure or timeout simply means "no wake this
        # cycle"; the next check cycle retries. -m 5 keeps this well inside the
        # watcher's per-check timeout so the supervision loop is never starved.
        $poll = Invoke-FmTool -FilePath $curl.Source -Arguments @(
            '-m', '5', '-s', '-o', $bodyFile, '-w', '%{http_code}',
            '-H', "@$headerFile",
            '-H', 'Accept: application/json',
            "$($config.Relay)/connector/poll")
        if (-not $poll.Ok) { Exit-FmScript 0 }
        $code = $poll.StdOut.Trim()

        # 204 (nothing pending) is the common path; only 200 can carry a mention.
        switch -CaseSensitive ($code) {
            '200' { }
            '204' { Clear-FmxPollError -State $state -BaseName $errorBase; Exit-FmScript 0 }
            { $_ -in @('400', '401', '403', '404') } {
                Write-FmxPollErrorOnce -State $state -BaseName $errorBase `
                    -Message "relay returned HTTP $code"
                Exit-FmScript 0
            }
            default { Exit-FmScript 0 }
        }

        $body = Get-FmFileText $bodyFile
        if ($body.Length -eq 0) {
            Clear-FmxPollError -State $state -BaseName $errorBase
            Exit-FmScript 0
        }

        # jq exits non-zero on a malformed payload and the bash twin takes that
        # as "no wake"; a parse failure here is the same answer.
        $payload = $null
        try {
            $payload = $body | ConvertFrom-Json -AsHashtable
        } catch {
            Exit-FmScript 0
        }
        # jq indexes `null` happily but errors on an array or a scalar.
        if ($null -ne $payload -and $payload -isnot [System.Collections.IDictionary]) {
            Exit-FmScript 0
        }

        $req = Get-FmxPollField -Record $payload -Name 'request_id'
        if ($req.Length -eq 0) {
            Clear-FmxPollError -State $state -BaseName $errorBase
            Exit-FmScript 0
        }

        # A pending mention only reaches the agent when it has non-empty text.
        # Semantic worthiness is decided by fmx-respond, so acknowledgments can
        # still be stashed here and deliberately skipped there.
        # Empty/absent/null text must not stash an inbox file or wake a public X
        # flow for nothing - stay inert (exit 0).
        $text = Get-FmxPollField -Record $payload -Name 'text'
        $text = [regex]::Replace($text, '\s+', ' ')
        $text = [regex]::Replace($text, '^ +| +$', '')
        if ($text.Length -eq 0) {
            Clear-FmxPollError -State $state -BaseName $errorBase
            Exit-FmScript 0
        }

        # Defend the inbox filename: request_id is relay-issued (e.g. "req-7"),
        # but never trust it into a path. Reject anything outside a safe slug.
        if ($req.StartsWith('.', [System.StringComparison]::Ordinal) -or -not [regex]::IsMatch($req, '^[A-Za-z0-9._-]+\z')) {
            Clear-FmxPollError -State $state -BaseName $errorBase
            Exit-FmScript 0
        }

        # The offer marker outlives the inbox file, which fmx-respond removes
        # after a successful answer or dismiss. Checking it before the inbox stash
        # keeps both a still-pending request and the relay's brief post-answer
        # re-offer silent without recreating a drained inbox. The startup prune
        # above bounds marker retention.
        if (Test-FmxPrivateArtifactFile -Directory "$state/x-context" -BaseName "$req.offered.json" -Mode '600') {
            Clear-FmxPollError -State $state -BaseName $errorBase
            Clear-FmxPollError -State $state -BaseName $claimErrorBase
            Exit-FmScript 0
        }

        # Stash the full mention object atomically so a concurrent reader never
        # sees a half-written file.
        $stash = (ConvertTo-Json -InputObject $payload -Depth 20) + "`n"
        if (-not (Publish-FmxPrivateArtifact -Directory "$state/x-inbox" -BaseName "$req.json" `
                    -Mode '600' -Text $stash)) {
            Write-FmxPollErrorOnce -State $state -BaseName $errorBase -Message 'cannot write inbox'
            Exit-FmScript 0
        }

        # Record the durable per-request reply context from the authoritative
        # relay payload, so a follow-up can recover the platform/budget even after
        # this inbox file is drained and even when no task link survives (the
        # single x_request per task collides across concurrent requests).
        # Best-effort: the inbox stash above is the primary artifact and the relay
        # lookup remains a fallback, so a registry write failure must never fail
        # the poll or touch its one-line stdout wake payload.
        # Set-FmxContextRegistryRecord is a no-op when the platform is unknown.
        $pollContext = Get-FmxReplyContextFromPayload -Path $bodyFile
        if (-not [string]::IsNullOrEmpty($pollContext)) {
            $record = $null
            try { $record = $pollContext | ConvertFrom-Json -AsHashtable } catch { $record = $null }
            $pollPlatform = Get-FmxPollField -Record $record -Name 'platform'
            $pollMax = Get-FmxPollField -Record $record -Name 'reply_max_chars'
            $null = Set-FmxContextRegistryRecord -State $state -RequestId $req `
                -Platform $pollPlatform -ReplyMax $pollMax
        }

        switch -CaseSensitive (Request-FmxOfferRegistryClaim -State $state -RequestId $req) {
            0 {
                Clear-FmxPollError -State $state -BaseName $errorBase
                Clear-FmxPollError -State $state -BaseName $claimErrorBase
                Write-FmOut "x-mention $req"
            }
            1 {
                Clear-FmxPollError -State $state -BaseName $errorBase
                Clear-FmxPollError -State $state -BaseName $claimErrorBase
                Exit-FmScript 0
            }
            default {
                Write-FmxPollErrorOnce -State $state -BaseName $claimErrorBase `
                    -Message 'cannot record mention offer'
                Exit-FmScript 0
            }
        }
    } finally {
        # The bash twin's EXIT trap: both temps go, on every path including a
        # mid-poll exit.
        try { [System.IO.File]::Delete($bodyFile) } catch { $null = $_ }
        if ($null -ne $headerFile) {
            try { [System.IO.File]::Delete((ConvertTo-FmNativePath $headerFile)) } catch { $null = $_ }
        }
    }

    Exit-FmScript 0
}
