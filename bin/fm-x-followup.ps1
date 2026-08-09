# Post a completion follow-up for an X-mode-linked task, up to three within a
# 7-day window, and manage the link's counter.
#
# Twin: bin/fm-x-followup.sh
#
# An X-mode mention that spawned real work is linked to its task by fm-x-link
# (x_request/x_request_ts/x_followups plus optional reply context in
# state/<id>.meta). When that task reaches a genuine milestone (investigation
# done, build started, shipped, failed), firstmate composes a public-safe outcome
# and posts it here as one of up to three follow-ups, within the window. Past the
# window, past the cap, or after --final, this clears the link so a later call is
# a clean no-op.
#
# Detection (no reply text needed - cheap pre-check before composing a reply):
#   fm-x-followup.ps1 --check <task-id>
#     exit 0, prints <request_id>  -> a follow-up is due (linked, within window
#                                      and cap)
#     exit 1, silent               -> not linked, or window/cap exhausted (link
#                                      pruned)
#
# Clear a legacy link without posting:
#   fm-x-followup.ps1 --clear <task-id>
#     idempotently removes only the X follow-up metadata for a typed terminal
#     outcome.
#
# Post (after composing the reply to a file or stdin):
#   fm-x-followup.ps1 <task-id> [--image <path>] [--final] --text-file <path>
#   fm-x-followup.ps1 <task-id> [--image <path>] [--final] -
#     Linked, within window, and under the cap: posts ONE follow-up via
#       fm-x-reply --followup.
#       On success: increments the counter and KEEPS the link, unless --final
#       was passed or the new count reaches the cap, in which case the link is
#       cleared instead - this is the "we're done" signal.
#       On a relay rejection distinguishing an exhausted cap/window (exit 9 from
#       fm-x-reply): clears the link and skips quietly, exactly like a
#       locally-detected expiry.
#       On fm-x-reply's fail-safe refusal (exit 8: platform or explicit budget
#       unresolved): KEEPS the link and exits non-zero. This is a RETRYABLE HOLD,
#       not an exhausted binding - retry once both values are recoverable rather
#       than posting with a local default.
#       On any other post failure: leaves the link in place so it can be
#       retried, exit non-zero.
#     Window or cap already exhausted: clears the link, posts nothing, exit 0
#       (silent skip).
#     Not linked: nothing to do, exit 0.
#
# --final marks this as the outcome reply: it always clears the link after a
# successful post, even if follow-ups remain under the cap.
#
# Dry-run (FMX_DRY_RUN) flows through fm-x-reply: the follow-up is recorded to
# state/x-outbox/<request_id>.json instead of posted, and the counter/link are
# mutated exactly as a live post would.
#
# The window is FMX_FOLLOWUP_MAX_AGE_SECS (default 604800, 7 days). The cap is
# FMX_FOLLOWUP_MAX_COUNT (default 3). FMX_NOW_OVERRIDE pins "now" for
# deterministic tests. Meta read/write lives in fm-x-lib.
#
# ---------------------------------------------------------------------------
# TWO MECHANICS THAT DIFFER FROM THE BASH TWIN
#
#   fm-x-reply IS REACHED THROUGH Invoke-FmScript, not through a hard-coded
#   "$FM_ROOT/bin/fm-x-reply.sh". The helper prefers the .ps1 twin and falls back
#   to the .sh under Git Bash, so this execute edge is correct in either
#   direction and cutover deletes one branch rather than editing this file
#   (docs/powershell-port.md, contract 7). -BinDir keeps it pointed at
#   FM_ROOT_OVERRIDE's bin exactly as the bash twin's $FM_ROOT/bin does.
#
#   THE CHILD'S STDERR IS RE-EMITTED, ITS STDOUT IS NOT. The bash twin redirects
#   only the child's stdout to /dev/null, so fm-x-reply's diagnostics (and its
#   DRY RUN summary) reach the caller's stderr. Invoke-FmScript captures both, so
#   the captured stderr is written back out verbatim and the stdout is dropped.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force

$fmArgv = @($args)

function Write-FmxFollowupUsage {
    [CmdletBinding()]
    param()
    Write-FmErr 'usage: fm-x-followup.sh --check <task-id> | --clear <task-id> | <task-id> [--image <path>] [--final] --text-file <path> | <task-id> [--image <path>] [--final] -'
}

function Write-FmxFollowupHelp {
    [CmdletBinding()]
    param()
    $lines = @(
        'usage: fm-x-followup.sh --check <task-id>'
        '       fm-x-followup.sh --clear <task-id>'
        '       fm-x-followup.sh <task-id> [--image <path>] [--final] --text-file <path>'
        '       fm-x-followup.sh <task-id> [--image <path>] [--final] -'
        ''
        'Post a completion follow-up (up to 3 per link, within a 7-day window) for an'
        "X-mode-linked task and manage the link's follow-up counter."
        ''
        'Options:'
        '  --check          Print the request_id when a follow-up is due.'
        '  --clear          Clear only the X follow-up link; never post.'
        '  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet or message.'
        '  --final          Clear the link after this post regardless of the remaining count.'
        '  --text-file <path>'
        '                   Read follow-up text from a file.'
        '  -                Read follow-up text from stdin.'
        '  --help           Show this help.'
    )
    foreach ($line in $lines) { Write-FmOut $line }
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State

    $maxAge = Get-FmEnv 'FMX_FOLLOWUP_MAX_AGE_SECS' '604800'
    if (-not [regex]::IsMatch($maxAge, '^[0-9]+\z')) { $maxAge = '604800' }
    $maxAgeValue = [long]$maxAge

    $maxCount = Get-FmEnv 'FMX_FOLLOWUP_MAX_COUNT' '3'
    if (-not [regex]::IsMatch($maxCount, '^[0-9]+\z')) { $maxCount = '3' }
    $maxCountValue = [long]$maxCount
    if ($maxCountValue -lt 1) { $maxCountValue = [long]3 }

    $first = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    if ($first -ceq '--help' -or $first -ceq '-h') {
        Write-FmxFollowupHelp
        Exit-FmScript 0
    }

    # Parse mode: --check is detection-only; otherwise it is a post, with the text
    # source (--text-file <path> | -) deferred until after the link/window/cap
    # check so a missing or exhausted link never consumes stdin or posts.
    $mode = 'post'
    $final = $false
    $id = ''
    $tsArgs = [System.Collections.Generic.List[string]]::new()
    if ($first -ceq '--clear' -or $first -ceq '--check') {
        $mode = if ($first -ceq '--clear') { 'clear' } else { 'check' }
        $id = if ($fmArgv.Count -gt 1) { [string]$fmArgv[1] } else { '' }
        if ([string]::IsNullOrEmpty($id) -or $fmArgv.Count -gt 2) {
            Write-FmxFollowupUsage
            Exit-FmScript 2
        }
    } else {
        $id = $first
        if ([string]::IsNullOrEmpty($id)) {
            Write-FmxFollowupUsage
            Exit-FmScript 2
        }
        $i = 1
        while ($i -lt $fmArgv.Count) {
            $arg = [string]$fmArgv[$i]
            if ($arg -ceq '--final') {
                $final = $true
            } elseif ($arg -ceq '--image') {
                $tsArgs.Add($arg)
                $i++
                if ($i -ge $fmArgv.Count -or [string]::IsNullOrEmpty([string]$fmArgv[$i])) {
                    Write-FmErr 'fm-x-followup: missing --image path'
                    Write-FmxFollowupUsage
                    Exit-FmScript 2
                }
                $tsArgs.Add([string]$fmArgv[$i])
            } else {
                $tsArgs.Add($arg)
            }
            $i++
        }
        if ($tsArgs.Count -lt 1) {
            Write-FmxFollowupUsage
            Exit-FmScript 2
        }
    }

    if ($id.StartsWith('.', [System.StringComparison]::Ordinal) -or -not [regex]::IsMatch($id, '^[A-Za-z0-9._-]+\z')) {
        Write-FmErr "fm-x-followup: unsafe task id: $id"
        Exit-FmScript 2
    }

    $meta = "$state/$id.meta"
    if ($mode -ceq 'clear') {
        if (-not (Clear-FmxMetaLink -MetaPath $meta)) {
            Write-FmErr "fm-x-followup: could not clear the link in state/$id.meta"
            Exit-FmScript 1
        }
        Write-FmOut $id
        Exit-FmScript 0
    }

    $rid = Get-FmxMetaValue -MetaPath $meta -Key 'x_request'
    $ts = Get-FmxMetaValue -MetaPath $meta -Key 'x_request_ts'
    $countRaw = Get-FmxMetaValue -MetaPath $meta -Key 'x_followups'
    $reqPlatform = Get-FmxMetaValue -MetaPath $meta -Key 'x_platform'
    $reqReplyMax = Get-FmxMetaValue -MetaPath $meta -Key 'x_reply_max_chars'
    $count = if ([regex]::IsMatch($countRaw, '^[0-9]+\z')) { [long]$countRaw } else { [long]0 }

    # Not linked: this task did not originate from an X-mode mention. Detection
    # fails; a post is simply a no-op success (firstmate need not special-case
    # it).
    if ([string]::IsNullOrEmpty($rid)) {
        if ($mode -ceq 'check') { Exit-FmScript 1 }
        Write-FmErr "fm-x-followup: $id is not X-linked; nothing to post"
        Exit-FmScript 0
    }

    $now = Get-FmEnv 'FMX_NOW_OVERRIDE'
    if ([string]::IsNullOrEmpty($now)) {
        $now = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString(
            [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if (-not [regex]::IsMatch($now, '^[0-9]+\z')) {
        Write-FmErr 'fm-x-followup: could not read the current time'
        Exit-FmScript 1
    }
    $nowValue = [long]$now

    # A missing or malformed timestamp cannot prove the follow-up is still in
    # window, so treat it like an elapsed window: prune the link and skip. Being
    # at or past the cap is pruned the same way.
    $expired = $false
    $reason = 'follow-up window elapsed'
    if (-not [regex]::IsMatch($ts, '^[0-9]+\z')) {
        $expired = $true
    } elseif (($nowValue - [long]$ts) -gt $maxAgeValue) {
        $expired = $true
    }
    if ($count -ge $maxCountValue) {
        $expired = $true
        $reason = 'follow-up cap reached'
    }

    if ($expired) {
        if (-not (Clear-FmxMetaLink -MetaPath $meta)) {
            Write-FmErr "fm-x-followup: warning: could not clear the elapsed link in state/$id.meta"
        }
        if ($mode -ceq 'check') { Exit-FmScript 1 }
        Write-FmErr "fm-x-followup: $reason for $id; skipped and cleared the link"
        Exit-FmScript 0
    }

    # Linked, within window, and under the cap.
    if ($mode -ceq 'check') {
        Write-FmOut $rid
        Exit-FmScript 0
    }

    # Post the follow-up. fm-x-reply owns text reading, thread-split, dry-run, the
    # endpoint, and the never-inline safety; we only pass the text source and any
    # recorded reply-platform context through.
    $replyEnv = [ordered]@{}
    if ($reqPlatform -ceq 'discord' -or $reqPlatform -ceq 'x') {
        $replyEnv['FMX_REPLY_PLATFORM'] = $reqPlatform
    }
    if ([regex]::IsMatch($reqReplyMax, '^[0-9]+\z')) {
        $replyEnv['FMX_REPLY_MAX_CHARS'] = $reqReplyMax
    }

    $saved = @{}
    foreach ($name in $replyEnv.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$replyEnv[$name])
    }
    $post = $null
    try {
        $post = Invoke-FmScript -Name 'fm-x-reply' -BinDir (Join-Path $ctx.Root 'bin') `
            -Arguments (@($rid, '--followup') + @($tsArgs.ToArray()))
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$post.StdErr)) {
        [Console]::Error.Write([string]$post.StdErr)
    }
    $postRc = [int]$post.ExitCode

    if ($postRc -eq 0) {
        $newCount = $count + 1
        if ($final -or $newCount -ge $maxCountValue) {
            if (-not (Clear-FmxMetaLink -MetaPath $meta)) {
                Write-FmErr "fm-x-followup: error: posted but could not clear the link in state/$id.meta"
                Exit-FmScript 1
            }
        } elseif (-not (Set-FmxMetaFollowupCount -MetaPath $meta -Count ([string]$newCount))) {
            if (-not (Clear-FmxMetaLink -MetaPath $meta)) {
                Write-FmErr "fm-x-followup: error: posted but could not record the follow-up count or clear the link in state/$id.meta"
                Exit-FmScript 1
            }
            Write-FmErr "fm-x-followup: warning: posted but could not record the follow-up count in state/$id.meta; cleared the link to avoid duplicate follow-ups"
        }
        Write-FmOut $rid
        Exit-FmScript 0
    }

    if ($postRc -eq 8) {
        # fm-x-reply refused this follow-up (exit 8) because it could not
        # authoritatively determine both the reply platform and explicit budget.
        # That is a RETRYABLE HOLD, not an exhausted binding: keep the link so the
        # follow-up can post once both values are recoverable. Never clear the
        # link here.
        Write-FmErr "fm-x-followup: follow-up for $id held: reply context lacks an authoritative platform or explicit budget; left the link in place to retry once both values are recoverable"
        Exit-FmScript 1
    }

    if ($postRc -eq 9) {
        # fm-x-reply distinguishes a relay rejection of this specific follow-up
        # (cap or window exhausted relay-side) with exit 9. Treat it exactly like
        # a locally-detected expiry: clear the link and skip quietly. This is also
        # the graceful-degradation path against an old relay that only ever
        # supported one follow-up - either way, retrying would never succeed.
        if (-not (Clear-FmxMetaLink -MetaPath $meta)) {
            Write-FmErr "fm-x-followup: warning: could not clear the rejected link in state/$id.meta"
        }
        Write-FmErr "fm-x-followup: relay rejected the follow-up for $id (cap or window exhausted); skipped and cleared the link"
        Exit-FmScript 0
    }

    # Post failed for another reason (network, auth, transport): leave the link so
    # firstmate can retry on a later pass.
    Write-FmErr "fm-x-followup: follow-up post failed for $id; left the link in place to retry"
    Exit-FmScript 1
}
