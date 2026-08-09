# Link a spawned task to the X-mode mention that triggered it, so firstmate can
# post up to THREE completion follow-ups when the task lands (within a 7-day window).
#
# Twin: bin/fm-x-link.sh
#
# Usage: fm-x-link.ps1 <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       link time, for the 7-day follow-up window
#   x_followups=<n>            follow-ups already posted against this binding
#   x_platform=<platform>      target platform, when known
#   x_reply_max_chars=<n>      target split budget, when known
#
# A fresh link always starts x_followups at 0 and uses the current time for
# x_request_ts. --carry-count <n> and --carry-ts <epoch> are a required pair for
# re-linking the SAME request onto a successor task (e.g. a stuck-crewmate
# recovery that respawns under a new task id): the caller reads the prior task's
# x_followups and x_request_ts before its meta goes away and passes both here,
# so the new task does not get a fresh follow-up budget, a refreshed local
# window, or a dropped reply-platform context against a binding the relay
# already knows about. Pass --carry-platform and --carry-max from the prior
# task's x_platform and x_reply_max_chars when the original inbox file is gone.
#
# Fresh-link context resolution fills platform and explicit budget independently
# through the durable per-request registry, inbox payload, then authoritative
# relay lookup by request_id. If either axis remains missing, the link is still
# recorded but a loud warning is printed and follow-ups fail closed.
#
# This is a separate step the fmx-respond skill runs AFTER fm-spawn, so it never
# changes fm-spawn's interface. The follow-up itself - detection, the window/cap
# check, the post, and clearing the link - is owned by fm-x-followup on the
# task's captain-relevant wakes. The meta read/write lives in fm-x-lib.
#
# Both ids are relay/firstmate slugs that compose a filename, so they are guarded
# against path traversal even though they come from trusted callers.
#
# ---------------------------------------------------------------------------
# WHAT DIFFERS FROM THE BASH TWIN
#
#   NO jq PRESENCE CHECK. The bash twin refuses with "jq not found" because it
#   parses the resolved reply context with jq; Resolve-FmxReplyContext answers
#   in-process here, so jq is not a dependency (docs/powershell-port.md).
#
#   THE CONTEXT-RESOLUTION FAILURE BRANCH IS UNREACHABLE, exactly as in
#   bin/fm-x-reply.ps1: Resolve-FmxReplyContext always answers, so an unresolved
#   axis surfaces through the loud WARNING below rather than through exit 1.
#
#   NO param() BLOCK: the bash CLI takes bare positional words, and a declared
#   parameter block would try to BIND them before the script runs.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force

$fmArgv = @($args)

function Write-FmxLinkUsage {
    [CmdletBinding()]
    param()
    Write-FmErr 'usage: fm-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]'
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State

    $id = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    $rid = if ($fmArgv.Count -gt 1) { [string]$fmArgv[1] } else { '' }
    if ([string]::IsNullOrEmpty($id) -or [string]::IsNullOrEmpty($rid)) {
        Write-FmxLinkUsage
        Exit-FmScript 2
    }

    $carryCount = ''
    $carryTs = ''
    $carryPlatform = ''
    $carryMax = ''
    $i = 2
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        switch -CaseSensitive ($arg) {
            '--carry-count' {
                $i++
                $carryCount = if ($i -lt $fmArgv.Count) { [string]$fmArgv[$i] } else { '' }
                if (-not [regex]::IsMatch($carryCount, '^[0-9]+\z')) {
                    Write-FmErr 'fm-x-link: --carry-count needs a non-negative integer'
                    Exit-FmScript 2
                }
            }
            '--carry-ts' {
                $i++
                $carryTs = if ($i -lt $fmArgv.Count) { [string]$fmArgv[$i] } else { '' }
                if (-not [regex]::IsMatch($carryTs, '^[0-9]+\z')) {
                    Write-FmErr 'fm-x-link: --carry-ts needs a non-negative epoch integer'
                    Exit-FmScript 2
                }
            }
            '--carry-platform' {
                $i++
                $carryPlatform = if ($i -lt $fmArgv.Count) { [string]$fmArgv[$i] } else { '' }
                if ($carryPlatform -ceq 'twitter') {
                    $carryPlatform = 'x'
                } elseif ($carryPlatform -cne 'discord' -and $carryPlatform -cne 'x') {
                    Write-FmErr 'fm-x-link: --carry-platform needs x or discord'
                    Exit-FmScript 2
                }
            }
            '--carry-max' {
                $i++
                $carryMax = if ($i -lt $fmArgv.Count) { [string]$fmArgv[$i] } else { '' }
                if (-not [regex]::IsMatch($carryMax, '^[0-9]+\z') -or [long]$carryMax -lt 50) {
                    Write-FmErr 'fm-x-link: --carry-max needs an integer of at least 50'
                    Exit-FmScript 2
                }
            }
            default {
                Write-FmxLinkUsage
                Exit-FmScript 2
            }
        }
        $i++
    }
    if (-not [string]::IsNullOrEmpty($carryCount) -and [string]::IsNullOrEmpty($carryTs)) {
        Write-FmErr 'fm-x-link: --carry-count requires --carry-ts to preserve the original follow-up window'
        Exit-FmScript 2
    }
    if (-not [string]::IsNullOrEmpty($carryTs) -and [string]::IsNullOrEmpty($carryCount)) {
        Write-FmErr 'fm-x-link: --carry-ts requires --carry-count to preserve the consumed follow-up count'
        Exit-FmScript 2
    }
    if ((-not [string]::IsNullOrEmpty($carryPlatform) -or -not [string]::IsNullOrEmpty($carryMax)) -and
        ([string]::IsNullOrEmpty($carryCount) -or [string]::IsNullOrEmpty($carryTs))) {
        Write-FmErr 'fm-x-link: --carry-platform and --carry-max require --carry-count and --carry-ts'
        Exit-FmScript 2
    }

    # task-id composes a path (state/<id>.meta); request_id composes a path
    # elsewhere (the inbox/outbox record). Reject anything outside a safe slug for
    # both.
    if (-not (Test-FmPrTaskId -Id $id)) {
        Write-FmErr "fm-x-link: unsafe task id: $id"
        Exit-FmScript 2
    }
    if ($rid.StartsWith('.', [System.StringComparison]::Ordinal) -or -not [regex]::IsMatch($rid, '^[A-Za-z0-9._-]+\z')) {
        Write-FmErr "fm-x-link: unsafe request_id: $rid"
        Exit-FmScript 2
    }

    $meta = "$state/$id.meta"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        Write-FmErr "fm-x-link: no such task: state/$id.meta"
        Exit-FmScript 1
    }

    $null = Get-FmxConfig -HomePath $ctx.Home
    $reqPlatform = ''
    $reqExplicitMax = ''
    $reqReplyMax = ''
    if (-not [string]::IsNullOrEmpty($carryPlatform)) { $reqPlatform = $carryPlatform }
    if (-not [string]::IsNullOrEmpty($carryMax)) { $reqReplyMax = $carryMax }

    if ([string]::IsNullOrEmpty($carryTs)) {
        $resolved = Resolve-FmxReplyContext -State $state -RequestId $rid -AllowRelay
        $record = $null
        try { $record = $resolved | ConvertFrom-Json -AsHashtable } catch { $record = $null }
        if ($record -is [System.Collections.IDictionary]) {
            if ($record.Contains('platform') -and $null -ne $record['platform']) {
                $reqPlatform = [string]$record['platform']
            } else {
                $reqPlatform = ''
            }
            if ($record.Contains('reply_max_chars') -and $null -ne $record['reply_max_chars']) {
                $reqExplicitMax = [string]$record['reply_max_chars']
            } else {
                $reqExplicitMax = ''
            }
        } else {
            $reqPlatform = ''
            $reqExplicitMax = ''
        }
        $reqReplyMax = $reqExplicitMax
    }

    if (-not [string]::IsNullOrEmpty($carryTs) -and
        ([string]::IsNullOrEmpty($reqPlatform) -or [string]::IsNullOrEmpty($reqReplyMax))) {
        Write-FmErr 'fm-x-link: relink requires carried reply context; pass --carry-platform and --carry-max from the prior task'
        Exit-FmScript 2
    }

    if ([string]::IsNullOrEmpty($carryTs) -and
        ([string]::IsNullOrEmpty($reqPlatform) -or [string]::IsNullOrEmpty($reqReplyMax))) {
        Write-FmErr "fm-x-link: WARNING: incomplete authoritative reply context for request $rid; every completion follow-up will be HELD until both platform and explicit budget can be resolved. Ensure the relay request-context lookup supplies both values."
    }

    $followups = '0'
    $linkTs = ''
    if (-not [string]::IsNullOrEmpty($carryTs)) {
        $linkTs = $carryTs
        $followups = $carryCount
    } else {
        # FMX_NOW_OVERRIDE keeps tests deterministic; production uses the wall
        # clock.
        $linkTs = Get-FmEnv 'FMX_NOW_OVERRIDE'
        if ([string]::IsNullOrEmpty($linkTs)) {
            $linkTs = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString(
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if (-not [regex]::IsMatch($linkTs, '^[0-9]+\z')) {
            Write-FmErr 'fm-x-link: could not read the current time'
            Exit-FmScript 1
        }
    }

    if (-not (Set-FmxMetaLink -MetaPath $meta -RequestId $rid -Timestamp $linkTs `
                -Followups $followups -Platform $reqPlatform -ReplyMax $reqReplyMax)) {
        Write-FmErr "fm-x-link: failed to record the link in state/$id.meta"
        Exit-FmScript 1
    }

    Write-FmOut "linked $id to X request $rid"
    Exit-FmScript 0
}
