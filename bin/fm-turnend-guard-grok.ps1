# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Twin: bin/fm-turnend-guard-grok.sh
#
# The exact running Stop payload selects one path. A typed native capability
# field delegates the shared guard's exit status and stderr directly back to
# that Grok process. Field absence preserves the pre-native one-resume fallback.
# Invalid or unreadable input starts neither path. Camel case has typed
# precedence over the legacy snake-case spelling when both are present.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES
#
# THIS FILE IS A ROUTER, AND ITS ONLY DANGEROUS OUTPUT IS EXIT 2. On the native
# path the shared guard's exit status IS this adapter's exit status, so 2 blocks
# the turn and 0 allows it; every other status the guard could produce collapses
# to 0, because a guard that failed unexpectedly must not block a captain's
# session. On the legacy path the adapter always exits 0 and instead queues ONE
# explicitly marked same-session resume.
#
# THE TWO jq GATES BECOME TWO IN-PROCESS PASSES, WITH THE SAME REFUSALS.
#
#   Gate 1 (`jq -n --stream ... | all(.[]; . == 1)`) exists to reject a payload
#   whose meaning is ambiguous: a duplicated sessionId/stopHookActive/
#   stop_hook_active key, or a structured value where a scalar belongs. It
#   counts STREAM LEAF EVENTS under each of those three root keys and requires
#   exactly one, so `{"sessionId":{"a":1,"b":2}}` is refused just as
#   `{"sessionId":"x","sessionId":"y"}` is. System.Text.Json's JsonDocument is
#   used rather than ConvertFrom-Json precisely because it PRESERVES duplicate
#   properties (verified on this host: ConvertFrom-Json -AsHashtable silently
#   keeps only the last, which would have let a duplicated key through).
#
#   Gate 2 (`jq -ser 'if length != 1 ...'`) requires exactly ONE document and
#   that it be an object, then types the capability field. A multi-document
#   payload makes JsonDocument.Parse throw on the trailing content (verified),
#   which is the same refusal - and it is why gate 1 needs no document counting
#   of its own.
#
# NO param() BLOCK and IMPORTS WITHOUT -Force, for the reasons
# bin/fm-turnend-guard.ps1's header records.
#
# THE OPERATIONAL ENCODER IS LOADED FROM $ROOT, NOT FROM $PSScriptRoot, exactly
# as the bash twin sources "$ROOT/bin/fm-operational-input.sh". The workspace
# root Grok reports is the tree whose guard is being run, and the encoded prompt
# must carry that tree's typed operational envelope. A root with no encoder is a
# missing prerequisite and exits 0 without starting either path.
#
# SIGNALS AND mktemp. The bash twin captures the guard's stderr through a
# temporary file removed by an EXIT trap; Invoke-FmScript returns both streams
# directly, so there is no temporary file to leak and no trap to lose to a
# signal Windows does not have (docs/powershell-port.md).

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force: see the conversion notes above.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# The three root keys gate 1 counts, and the fallback reason the legacy path
# uses when the shared guard blocked without saying why.
$script:FmGrokCountedKeys = @('sessionId', 'stopHookActive', 'stop_hook_active')
$script:FmGrokFallbackReason = 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

<#
.SYNOPSIS
The number of `jq --stream` LEAF events a JSON value would produce.
.DESCRIPTION
A scalar is one leaf. An EMPTY container is also one leaf, because jq streams it
as a single `[path, []]` event rather than descending into it. A non-empty
container is the sum of its children's leaves. That is the whole rule gate 1
counts with, and reproducing it is what makes a structured value where a scalar
belongs refuse identically in both worlds.
#>
function Get-FmGrokLeafCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $total = 0
            foreach ($property in $Element.EnumerateObject()) {
                $total += Get-FmGrokLeafCount -Element $property.Value
            }
            if ($total -eq 0) { return 1 }
            return $total
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $total = 0
            foreach ($item in $Element.EnumerateArray()) {
                $total += Get-FmGrokLeafCount -Element $item
            }
            if ($total -eq 0) { return 1 }
            return $total
        }
        default { return 1 }
    }
}

<#
.SYNOPSIS
The payload's capability - 'native', 'legacy', or $null for "start no path".
.DESCRIPTION
Both jq gates in one pass over one parsed document, in the bash twin's order:

  1. the payload must be exactly one parseable JSON document;
  2. each of sessionId / stopHookActive / stop_hook_active that appears at all
     must contribute exactly one stream leaf (gate 1);
  3. the document must be an object;
  4. a present stopHookActive must be a boolean, otherwise the payload is
     refused - and only when that spelling is ABSENT is stop_hook_active
     consulted, which is the typed camel-case precedence;
  5. neither spelling present means a genuine pre-native payload: 'legacy'.
#>
function Get-FmGrokCapability {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Payload)
    } catch {
        return $null
    }

    try {
        $root = $document.RootElement

        if ($root.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $counts = @{}
            foreach ($property in $root.EnumerateObject()) {
                # -cnotcontains: JSON keys are case-sensitive and so is jq, so
                # "SessionId" must not be counted as "sessionId".
                if ($script:FmGrokCountedKeys -cnotcontains $property.Name) { continue }
                $seen = 0
                if ($counts.ContainsKey($property.Name)) { $seen = [int]$counts[$property.Name] }
                $counts[$property.Name] = $seen + (Get-FmGrokLeafCount -Element $property.Value)
            }
            foreach ($key in $counts.Keys) {
                if ([int]$counts[$key] -ne 1) { return $null }
            }
        } else {
            # A non-object root can carry none of the three keys at its own
            # level, so gate 1 passes vacuously and gate 2 refuses it below -
            # exactly the order the two jq programs apply.
            return $null
        }

        foreach ($key in @('stopHookActive', 'stop_hook_active')) {
            $value = [System.Text.Json.JsonElement]::new()
            if (-not $root.TryGetProperty($key, [ref]$value)) { continue }
            if ($value.ValueKind -ne [System.Text.Json.JsonValueKind]::True -and
                $value.ValueKind -ne [System.Text.Json.JsonValueKind]::False) {
                return $null
            }
            return 'native'
        }
        return 'legacy'
    } finally {
        $document.Dispose()
    }
}

<#
.SYNOPSIS
The payload's sessionId when it is a non-empty string, otherwise $null.
.DESCRIPTION
Twin of `jq -er '.sessionId | select(type == "string" and length > 0)'`, whose
`select` failure is what makes the whole legacy path decline rather than resume
a session it cannot name.
#>
function Get-FmGrokSessionId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Payload)
    } catch {
        return $null
    }
    try {
        $value = [System.Text.Json.JsonElement]::new()
        if (-not $document.RootElement.TryGetProperty('sessionId', [ref]$value)) { return $null }
        if ($value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { return $null }
        $text = $value.GetString()
        if ([string]::IsNullOrEmpty($text)) { return $null }
        return $text
    } catch {
        return $null
    } finally {
        $document.Dispose()
    }
}

<#
.SYNOPSIS
Re-emit a child's captured stderr on this process's stderr, byte for byte.
.DESCRIPTION
The bash twin never captures the guard's stderr on the native path at all - it
inherits the stream - so the bytes Grok reads are the guard's own. Capturing and
re-emitting is what Invoke-FmScript's honest three-channel split costs, and this
keeps the round trip exact: the final LF is removed before the split and
restored by Write-FmErr, so a stream that ended with one still ends with exactly
one. Nothing is written for an empty stream, where a naive single call would
have emitted a bare newline.
#>
function Write-FmGrokPassthroughError {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return }
    $body = $Text
    if ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
    foreach ($line in ($body -split "`n")) { Write-FmErr $line }
}

<#
.SYNOPSIS
The whole adapter, returning the process exit code instead of taking it.
#>
function Invoke-FmTurnendGuardGrok {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $payload = ''
    try { $payload = [Console]::In.ReadToEnd() } catch { $payload = '' }
    if ($null -eq $payload) { $payload = '' }
    # `$(cat)` strips trailing newlines, so a payload of nothing but newlines is
    # empty in both worlds.
    $payload = $payload.TrimEnd("`n")
    if ($payload -eq '') { return 0 }

    $capability = Get-FmGrokCapability -Payload $payload
    if ([string]::IsNullOrEmpty($capability)) { return 0 }

    $root = Get-FmEnv -Name 'GROK_WORKSPACE_ROOT'
    if ([string]::IsNullOrEmpty($root)) { $root = Get-FmEnv -Name 'CLAUDE_PROJECT_DIR' }
    if ([string]::IsNullOrEmpty($root)) { return 0 }
    # `${ROOT%/}` - one trailing separator, in either spelling.
    $root = $root.TrimEnd('/', '\')
    if ([string]::IsNullOrEmpty($root)) { return 0 }

    # `[ -x "$ROOT/bin/fm-turnend-guard.sh" ]`, transition-safe: whichever twin
    # is present is the prerequisite. The executable bit is deliberately NOT
    # enforced - on Windows chmod is inert and every path reads 755, so a real
    # ACL check would refuse artifacts the bash path accepts
    # (docs/powershell-port.md, "Things that must NOT be improved").
    $binDir = "$root/bin"
    $guardPresent = $false
    foreach ($candidate in @("$binDir/fm-turnend-guard.ps1", "$binDir/fm-turnend-guard.sh")) {
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $candidate))) { $guardPresent = $true }
    }
    if (-not $guardPresent) { return 0 }

    if ($capability -ceq 'native') {
        $run = Invoke-FmScript -Name 'fm-turnend-guard' -BinDir $binDir -StdIn $payload
        # The guard's own streams belong to Grok: this adapter's whole native
        # contract is to delegate the status AND the feedback unchanged.
        Write-FmRaw $run.StdOut
        Write-FmGrokPassthroughError $run.StdErr
        if ($run.ExitCode -eq 0 -or $run.ExitCode -eq 2) { return $run.ExitCode }
        return 0
    }

    # Only a genuine pre-native payload reaches this bounded compatibility path.
    if (-not [string]::IsNullOrEmpty((Get-FmEnv -Name 'GROK_TURNEND_GUARD_ACTIVE'))) { return 0 }
    $sessionId = Get-FmGrokSessionId -Payload $payload
    if ([string]::IsNullOrEmpty($sessionId)) { return 0 }
    if (-not (Test-FmCommand 'grok')) { return 0 }

    $run = Invoke-FmScript -Name 'fm-turnend-guard' -BinDir $binDir -StdIn $payload
    # The bash twin captures only stderr; the guard's stdout still reaches the
    # caller, so it is forwarded here too.
    Write-FmRaw $run.StdOut
    if ($run.ExitCode -ne 2) { return 0 }

    $reason = $run.StdErr.TrimEnd("`n")
    if ([string]::IsNullOrEmpty($reason)) { $reason = $script:FmGrokFallbackReason }

    try {
        Import-Module (Join-Path (ConvertTo-FmNativePath $binDir) 'fm-operational-input.psm1')
    } catch {
        # `. "$ROOT/bin/fm-operational-input.sh"` failing leaves the encoder
        # undefined and the `|| exit 0` below takes over; the same outcome
        # without the shell's noisy source diagnostic.
        return 0
    }
    $body = "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.`n`n$reason"
    $prompt = ConvertTo-FmOperationalInput -Kind 'turn-end-guard' -Body $body
    if ([string]::IsNullOrEmpty($prompt)) { return 0 }

    # -First 1: a name can resolve to more than one application on PATH (a real
    # binary plus a Windows app-execution alias is the common shape), and
    # .Source on the resulting ARRAY fails to bind to a [string] parameter.
    # PATH order picks the winner, exactly as `command -v` does for the bash
    # twin.
    $grokCommand = @(Get-Command 'grok' -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if ($null -eq $grokCommand) { return 0 }

    $grokHome = Get-FmEnv -Name 'GROK_HOME'
    if ([string]::IsNullOrEmpty($grokHome)) {
        $userHome = Get-FmEnv -Name 'HOME'
        if ([string]::IsNullOrEmpty($userHome)) { $userHome = $HOME }
        $grokHome = "$userHome/.grok"
    }

    $previousActive = [Environment]::GetEnvironmentVariable('GROK_TURNEND_GUARD_ACTIVE')
    $previousHome = [Environment]::GetEnvironmentVariable('GROK_HOME')
    try {
        # The bash twin sets both for the child only, through a command prefix;
        # this process has no fork to scope them to, so they are set, used, and
        # restored around the one call.
        [Environment]::SetEnvironmentVariable('GROK_TURNEND_GUARD_ACTIVE', '1')
        [Environment]::SetEnvironmentVariable('GROK_HOME', $grokHome)
        $null = Invoke-FmTool -FilePath $grokCommand.Source -Arguments @(
            '--resume', $sessionId,
            '--cwd', $root,
            '--output-format', 'plain',
            '-p', $prompt
        )
    } catch {
        # `|| true`: a resume that could not be started is not this adapter's
        # failure to report - the synchronous guard already spoke.
        $null = $_
    } finally {
        [Environment]::SetEnvironmentVariable('GROK_TURNEND_GUARD_ACTIVE', $previousActive)
        [Environment]::SetEnvironmentVariable('GROK_HOME', $previousHome)
    }
    return 0
}

# Not Invoke-FmMain: 2 is the BLOCK signal and an escaped exception must never
# produce it. See bin/fm-turnend-guard.ps1's tail for the same reasoning.
$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmTurnendGuardGrok)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
