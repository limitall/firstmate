# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.ps1 <target> [--resolve-key <key>]... <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.ps1 <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Twin: bin/fm-send.sh
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.psm1.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text uses the live-charter-compatible
# from-firstmate carrier owned by bin/fm-operational-input.psm1 so the secondmate
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/fm-pending-reply-lib.psm1). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set FM_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked captain input never creates one.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. After the submit is
# confirmed, fm-send itself appends the closing
# "resolved [key=<key>]: answered: <capped excerpt>" line to that status file,
# so the captain-facing OPEN DECISIONS record closes at answer time and never
# depends on the busy worker writing a matching resolved line. The close is a
# LOCAL append for every target kind - crewmate, scout and local secondmate
# alike - because the open-decision ledger fm-wake-drain folds lives in this
# home's own state dir; only the answer message crosses the backend. Each named
# key must currently be open in that ledger per Get-FmStatusOpenDecisions
# (bin/fm-classify-lib.psm1) or fm-send refuses before sending, so a mistyped key
# cannot deliver an answer while silently orphaning the decision. A failed or
# unconfirmed send never closes a key; a delivered answer whose closing append
# fails exits nonzero with the exact manual close command, leaving the decision
# open to re-surface (the safe direction). A send without the flag never closes
# anything: a routine steer, working:, or done: event still cannot clear a
# captain decision. The flag is refused with --key, with an explicit backend
# target (no task ledger in this home), and with an empty message.
#
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
#
# ---------------------------------------------------------------------------
# THE FIVE THINGS THIS CONVERSION HAD TO GET EXACTLY RIGHT
#
#   1. THE FM_HOME REFUSAL IS THE FIRST FLEET-SAFETY GATE, and it distinguishes
#      unset from empty exactly as bash's `${FM_HOME+x}` / `${FM_HOME:-}` pair
#      does - both refuse. AGENTS.md section 2: a steer must never silently
#      resolve against another home, so this runs before anything reads state,
#      and after only the gate-agent refusal (which must precede every fleet
#      mutation). [Environment]::GetEnvironmentVariable is used rather than
#      Get-FmEnv for the "set but empty" half, because the two cases produce the
#      same refusal here and conflating them would lose that intent in review.
#
#   2. NO CLASSIFICATION IS REIMPLEMENTED. Typing once and retrying ENTER ONLY
#      is the composer contract, and it lives in bin/fm-composer-lib.psm1 and the
#      backend adapters. This script only chooses the settle, hands the message
#      over, and branches on the returned verdict - because a second copy of the
#      "did it submit" rule that drifted would re-type a captain instruction into
#      a live agent, the exact failure the verified-submit design exists to
#      prevent. Only the exact verdict `empty` is success.
#
#   3. PATHS KEEP THE CALLER'S SPELLING. Every resolution diagnostic embeds
#      `$STATE/...`, and the bash twins print the MSYS form. So STATE is built by
#      string concatenation and the meta path is COMPOSED from the resolved task
#      id rather than taken from the backend module's native-form answer (which
#      is correct for .NET but would print F:\... where the twin prints /f/...).
#      Both forms are accepted by every reader, so the composed path is passed on
#      unchanged.
#
#   4. THE PENDING-REPLY LIFECYCLE IS TRANSACTIONAL, and its failure directions
#      are not symmetric. A transport failure DISCARDS the undelivered
#      expectation (otherwise a never-sent request would later escalate as a
#      missed report); a delivery-commit failure does NOT, because the text did
#      land - it reports "do not resend" and exits non-zero. Exit code 1 covers
#      both, as in the twin; the two are distinguished by the message only.
#
#   5. --resolve-key IS ORDERED AROUND DELIVERY, IN BOTH DIRECTIONS. Every
#      refusal - malformed key, duplicate key, an explicit backend target with no
#      ledger here, --key, an empty answer, a key that is not currently open -
#      happens BEFORE anything is typed, so a mistyped key can never deliver an
#      answer while orphaning its decision. The closing append happens only after
#      the submit verdict is exactly `empty` AND the pending-reply delivery
#      commit succeeded, so a failed, unconfirmed, or uncommitted send leaves the
#      decision open. The one remaining asymmetry is deliberate: if the append
#      itself fails after the answer landed, fm-send exits non-zero with the
#      literal manual close command rather than retrying or swallowing it - the
#      decision re-surfacing is the safe direction, resending the answer is not.
#      The open-set test is Get-FmStatusOpenDecisions, the SAME fold
#      fm-wake-drain's OPEN DECISIONS section uses; a second copy of the
#      open/resolved rule here would drift and close the wrong things.
#
# ---------------------------------------------------------------------------
# DOCUMENTED DIVERGENCES
#
#   THE GUARD'S STREAMS ARE INHERITED, NOT CAPTURED (-Stream), so its banner
#   reaches the terminal in the same order and with the same bytes as the bash
#   twin's direct invocation. A differential driver that redirects the console
#   in-process cannot observe a child's output, so the suite keeps the guard
#   silent by fixture rather than by capturing it here.
#
#   FM_SEND_SETTLE ACCEPTS A NUMBER. `sleep abc` fails in the twin (and, as the
#   last command under `set -eu`, ends the script non-zero); an unparseable value
#   is treated as "no settle" here rather than fabricating that failure.
#
#   A FAILED CLOSING APPEND PRINTS ONE LINE, NOT TWO. When `>> $status` fails,
#   the bash twin's SHELL first prints its own redirection diagnostic
#   ("fm-send.sh: line N: <path>: Permission denied") and fm-send's own refusal
#   follows it. PowerShell has no shell-level redirection to fail, so this twin
#   prints only fm-send's refusal. Verified differentially with a read-only
#   status file: same exit code, same refusal text including the literal manual
#   close command; the twin simply does not fabricate the shell's line.
#
#   MISSING --key ARGUMENT. `fm-send.sh <t> --key` with no key dies on `$2`
#   under `set -u`; the twin refuses with its own message and the same exit 1.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-gate-refuse-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-control-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-marker-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pending-reply-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force
# NOT -Force: fm-line-cap-lib's own header pins the plain import form. It is a
# definitions-only module with no import-time side effect, so there is nothing a
# fresh copy would buy, and the plain form is what every other consumer uses.
Import-Module (Join-Path $PSScriptRoot 'fm-line-cap-lib.psm1')

# No param() block, and $args captured here: see bin/fm-operational-input.ps1.
$fmArgv = @($args)

# Resolution results, mirroring the bash twin's RESOLVED_TARGET/TARGET_* globals
# so the diagnostics further down can name what was tried.
$script:ResolvedTarget = ''
$script:TargetBackend = ''
$script:TargetHarness = ''
$script:ExpectedLabel = ''
$script:TargetMeta = ''
$script:TargetSelector = $false
$script:ResolutionTried = ''

# The task id half of a `state/<id>.meta` path.
function Get-FmSendIdFromMeta {
    param([Parameter(Mandatory)][string]$MetaPath)
    $base = $MetaPath
    $slash = [System.Math]::Max($base.LastIndexOf('/'), $base.LastIndexOf('\'))
    if ($slash -ge 0) { $base = $base.Substring($slash + 1) }
    if ($base.EndsWith('.meta')) { $base = $base.Substring(0, $base.Length - 5) }
    return $base
}

# The first `state/*.meta` whose <key> equals <value>, in the same ordinal order
# the bash glob produces, or '' when none matches. The path is returned in the
# STATE spelling the caller passed in (see note 3 in the header).
function Get-FmSendMetaForKeyValue {
    param([string]$StateDir, [string]$Key, [string]$Value)
    $native = ConvertTo-FmNativePath $StateDir
    if (-not [System.IO.Directory]::Exists($native)) { return '' }
    $metas = @([System.IO.Directory]::EnumerateFiles($native, '*.meta'))
    [Array]::Sort($metas, [System.StringComparer]::Ordinal)
    foreach ($meta in $metas) {
        if ((Get-FmMetaValue $meta $Key) -ceq $Value) {
            return "$StateDir/" + [System.IO.Path]::GetFileName($meta)
        }
    }
    return ''
}

Invoke-FmMain -UnexpectedCode 70 {
    # FM_ROOT is needed for the busy-event edge below; FM_HOME is NOT defaulted
    # from it here, unlike every other entrypoint - see note 1 in the header.
    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
    }

    # Fail closed before any fleet mutation: a no-mistakes gate agent must never
    # steer a crewmate (see bin/fm-gate-refuse-lib.psm1).
    Assert-FmNotGateAgent

    $fmHome = [Environment]::GetEnvironmentVariable('FM_HOME')
    if ($null -eq $fmHome -or $fmHome -eq '') {
        Write-FmErr 'error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home'
        Exit-FmScript 1
    }

    $state = Get-FmEnv 'FM_STATE_OVERRIDE' "$fmHome/state"
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $fmHome))) {
        Write-FmErr "error: FM_HOME '$fmHome' is not a directory; fm-send cannot resolve this home's state"
        Exit-FmScript 1
    }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $state))) {
        Write-FmErr "error: state dir '$state' is missing; fm-send cannot resolve targets for FM_HOME '$fmHome'"
        Exit-FmScript 1
    }

    # `FM_GUARD_CONTINUE_LINE=... fm-guard.sh || true`: a one-command prefix
    # assignment, so the variable is restored afterwards rather than leaking into
    # the backend calls below.
    $priorContinue = [Environment]::GetEnvironmentVariable('FM_GUARD_CONTINUE_LINE')
    [Environment]::SetEnvironmentVariable('FM_GUARD_CONTINUE_LINE',
        'This is a supervision warning only; the requested message WILL still be sent.')
    try {
        $null = Invoke-FmScript 'fm-guard' -Stream
    } finally {
        [Environment]::SetEnvironmentVariable('FM_GUARD_CONTINUE_LINE', $priorContinue)
    }

    # `fm_send_normalize_key`: collapse the accepted spellings of the cancel key
    # onto the ONE semantic name the two interrupt follow-ups below branch on, so
    # `--key esc` gets the same composer clear and the same busy-state record as
    # `--key Escape`. Every other key passes through untouched, and the RAW key
    # is still what reaches the backend - only firstmate's own bookkeeping reads
    # the normalized form.
    function ConvertTo-FmSendSemanticKey {
        param([AllowEmptyString()][AllowNull()][string]$Key = '')
        if ($null -eq $Key) { $Key = '' }
        if ($Key -cin @('Escape', 'escape', 'Esc', 'esc')) { return 'Escape' }
        return $Key
    }

    # `fm_send_clear_after_interrupt`: muse RESTORES the interrupted prompt back
    # into the composer when Escape cancels a turn, as real BRIGHT text (verified:
    # fg 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised
    # ghost text. Classifying that as pending input is correct - the text really
    # is unsubmitted - but leaving it there means the NEXT steer types onto the
    # end of it and submits both as one garbled message. Ctrl-U clears the
    # composer (verified), so the interrupt is not complete until it has been
    # sent. A failed clear is LOUD rather than silent, because the alternative is
    # a corrupted steer.
    #
    # WHICH adapters need that clear, and which key clears them, comes from the
    # one control-plane capability table (bin/fm-control-lib.psm1) rather than a
    # second copy here - the same table bin/fm-control.ps1's interrupt verb
    # reads, and the exact seam the bash twin uses. Two copies WOULD drift, and
    # the drift would be silent: a steer typed onto the end of a restored prompt
    # is delivered, just garbled.
    #
    # The two lookups answer on one channel each, where bash answered on two
    # (docs at bin/fm-control-lib.psm1): an unrecognized harness yields $null
    # from the family lookup and a verified adapter that needs no clear yields
    # ''. bash's `family=$(...) || return 0` and `[ -n "$clear" ] || return 0`
    # collapse both to "nothing more to send", which is what the two
    # IsNullOrEmpty guards below do.
    function Invoke-FmSendComposerClear {
        param([string]$Key, [string]$Target)
        if ($Key -cne 'Escape') { return $true }
        $family = Get-FmControlHarnessFamily $script:TargetHarness
        if ([string]::IsNullOrEmpty($family)) { return $true }
        $clear = Get-FmControlInterruptClearKey $family
        if ([string]::IsNullOrEmpty($clear)) { return $true }
        if ($script:TargetBackend -ceq 'remote') { return $true }
        if (Send-FmBackendKey -Backend $script:TargetBackend -Target $Target -Key $clear `
                -ExpectedLabel $script:ExpectedLabel) {
            return $true
        }
        Write-FmErr ("error: Escape reached $Target, but the $($script:TargetHarness) composer could not " +
            'be cleared; it still holds the restored prompt. Clear it before sending the next message.')
        return $false
    }

    # Record a Claude interrupt so the busy fold stops reporting a turn that the
    # Escape just ended. Only Escape, only a claude* harness, only a task with a
    # busy generation recorded.
    function Write-FmSendInterrupt {
        param([string]$Key, [string]$Target)
        if ($Key -cne 'Escape') { return $true }
        if (-not ($script:TargetHarness -clike 'claude*')) { return $true }
        if ([string]::IsNullOrEmpty($script:TargetMeta)) { return $true }
        $id = Get-FmSendIdFromMeta -MetaPath $script:TargetMeta
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath "$state/$id.busy-gen"))) { return $true }
        $gen = Get-FmMetaValue $script:TargetMeta 'busy_gen'
        $busyEventArgs = if ([string]::IsNullOrEmpty($gen)) {
            @('apply', $state, $id, 'idle', '--current-gen', '--source', 'fm-interrupt', '--event', 'interrupt')
        } else {
            @('apply', $state, $id, 'idle', '--gen', $gen, '--source', 'fm-interrupt', '--event', 'interrupt')
        }
        $result = Invoke-FmScript 'fm-busy-event' $busyEventArgs -BinDir (ConvertTo-FmNativePath "$fmRoot/bin") -Stream
        if ($result.Ok) { return $true }
        Write-FmErr "error: key '$Key' reached $Target, but the Claude interrupt state could not be recorded for $id"
        return $false
    }

    function Resolve-FmSendTarget {
        param([string]$Raw)

        $script:ResolvedTarget = ''
        $script:TargetBackend = ''
        $script:TargetHarness = ''
        $script:ExpectedLabel = ''
        $script:TargetMeta = ''
        $script:TargetSelector = $false
        $script:ResolutionTried = ''

        # Composed in the caller's path spelling, not taken from the module's
        # native-form answer (note 3 in the header).
        $taskId = Get-FmBackendTaskIdForSelector -Raw $Raw -StateDir $state
        if (-not [string]::IsNullOrEmpty($taskId)) {
            $meta = "$state/$taskId.meta"
            $script:ResolutionTried = "meta=$meta; backend=from-meta"
            $target = Get-FmBackendTargetOfMeta $meta
            if ([string]::IsNullOrEmpty($target)) {
                Write-FmErr "error: no backend target recorded in $meta (tried $($script:ResolutionTried))"
                return $false
            }
            $script:ResolvedTarget = $target
            $script:TargetBackend = Get-FmBackendOfMeta $meta
            $script:TargetMeta = $meta
            $script:TargetHarness = Get-FmMetaValue $meta 'harness'
            $script:ExpectedLabel = Get-FmBackendExpectedLabelOfSelector -Raw $Raw -StateDir $state
            $script:TargetSelector = $true
            return $true
        }

        if ($Raw.StartsWith('fm-', [System.StringComparison]::Ordinal)) {
            $script:ResolutionTried = "meta=$state/$Raw.meta; legacy-meta=$state/$($Raw.Substring(3)).meta; backend=none"
            Write-FmErr ("error: no metadata for $Raw in $state (tried $($script:ResolutionTried)); " +
                'pass a well-formed explicit backend target only when targeting outside this firstmate home')
            return $false
        }

        $paneMeta = Get-FmSendMetaForKeyValue -StateDir $state -Key 'herdr_pane_id' -Value $Raw
        if (-not [string]::IsNullOrEmpty($paneMeta)) {
            $session = Get-FmMetaValue $paneMeta 'herdr_session'
            $hint = if ([string]::IsNullOrEmpty($session)) { "<herdr-session>:$Raw" } else { "${session}:$Raw" }
            $id = Get-FmSendIdFromMeta -MetaPath $paneMeta
            Write-FmErr ("error: target '$Raw' matches herdr_pane_id in $paneMeta but is missing its herdr " +
                "session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' " +
                "(tried meta=$state/$Raw.meta; backend=herdr)")
            return $false
        }

        $windowMeta = Get-FmBackendMetaForWindow -Target $Raw -StateDir $state
        if (-not [string]::IsNullOrEmpty($windowMeta)) {
            $windowMeta = "$state/" + [System.IO.Path]::GetFileName($windowMeta)
            $target = Get-FmBackendTargetOfMeta $windowMeta
            if ([string]::IsNullOrEmpty($target)) {
                Write-FmErr ("error: no backend target recorded in $windowMeta (tried explicit target " +
                    "'$Raw' via recorded window/terminal; backend=from-meta)")
                return $false
            }
            $script:ResolvedTarget = $target
            $script:TargetBackend = Get-FmBackendOfMeta $windowMeta
            $script:TargetMeta = $windowMeta
            $script:TargetHarness = Get-FmMetaValue $windowMeta 'harness'
            $script:ResolutionTried = "explicit target '$Raw' matched $windowMeta; backend=$($script:TargetBackend)"
            return $true
        }

        if ($Raw.Contains(':')) {
            # Two or more colons is herdr's <session>:<window>:<pane> shape; one
            # is tmux's <session>:<window>.
            $colons = ($Raw.Length - ($Raw -replace ':', '').Length)
            $assumed = if ($colons -ge 2) { 'herdr' } else { 'tmux' }
            if (-not (Test-FmBackendTargetExists -Backend $assumed -Target $Raw)) {
                Write-FmErr ("error: explicit target '$Raw' is not a live $assumed endpoint (tried " +
                    "meta=$state/$Raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> " +
                    'for a recorded task/lane, or pass a target whose backend endpoint can be verified.')
                return $false
            }
            $script:ResolvedTarget = $Raw
            $script:TargetBackend = $assumed
            $script:ResolutionTried = "meta=$state/$Raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
            return $true
        }

        Write-FmErr ("error: target '$Raw' is not resolvable (tried meta=$state/$Raw.meta; metadata " +
            "window/terminal lookup; backend=none). Use fm-$Raw for a recorded task/lane, or pass a " +
            'well-formed explicit backend target such as session:window.')
        return $false
    }

    if ($fmArgv.Count -lt 1) {
        Write-FmErr 'usage: fm-send.sh <target> <text...>'
        Exit-FmScript 1
    }
    $rawTarget = [string]$fmArgv[0]
    if (-not (Resolve-FmSendTarget -Raw $rawTarget)) { Exit-FmScript 1 }
    $target = $script:ResolvedTarget
    $rest = @($fmArgv | Select-Object -Skip 1)

    # Collect --resolve-key flags (answerer-closes; see the header contract).
    # They must precede --key or the message text; everything after the last flag
    # is the message exactly as before, so ordinary sends are byte-identical.
    # The list is mutated in place rather than returned because a PowerShell
    # function cannot assign to its caller's variable, and returning a rebuilt
    # array through the output stream would unroll a one-key set to a bare string
    # (docs/powershell-port.md).
    function Add-FmSendResolveKey {
        param(
            # AllowEmptyCollection is load-bearing, not decoration: a Mandatory
            # parameter REFUSES an empty collection, and the list is empty on the
            # very first --resolve-key, so without it every answer send fails to
            # bind before it can validate anything.
            [Parameter(Mandatory)][AllowEmptyCollection()]
            [System.Collections.Generic.List[string]]$Keys,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Key
        )
        # `case "$k" in ''|*[!A-Za-z0-9._-]*)`. \A and \z rather than ^ and $:
        # .NET's $ also matches BEFORE a trailing newline, so "abc`n" would pass a
        # ^...$ test that the bash character-class test rejects.
        if ($Key -cnotmatch '\A[A-Za-z0-9._-]+\z') {
            Write-FmErr "error: --resolve-key '$Key' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)"
            return $false
        }
        # List<string>.Contains is ordinal, matching bash's exact `case " $RESOLVE_KEYS "`
        # membership test (a key can hold no space, so that test is exact too).
        if ($Keys.Contains($Key)) {
            Write-FmErr "error: duplicate --resolve-key '$Key'"
            return $false
        }
        $Keys.Add($Key)
        return $true
    }

    $resolveKeys = [System.Collections.Generic.List[string]]::new()
    $consumed = 0
    while ($consumed -lt $rest.Count) {
        $flag = [string]$rest[$consumed]
        if ($flag -ceq '--resolve-key') {
            if ($consumed + 1 -ge $rest.Count) {
                Write-FmErr 'error: --resolve-key requires a key'
                Exit-FmScript 1
            }
            if (-not (Add-FmSendResolveKey -Keys $resolveKeys -Key ([string]$rest[$consumed + 1]))) {
                Exit-FmScript 1
            }
            $consumed += 2
        } elseif ($flag.StartsWith('--resolve-key=', [System.StringComparison]::Ordinal)) {
            if (-not (Add-FmSendResolveKey -Keys $resolveKeys -Key $flag.Substring('--resolve-key='.Length))) {
                Exit-FmScript 1
            }
            $consumed += 1
        } else {
            break
        }
    }
    # `shift`: assigned inside each branch, never as `$rest = if (...) {...}`,
    # which would unroll a one-element remainder to a bare string.
    if ($consumed -gt 0) {
        if ($consumed -ge $rest.Count) {
            $rest = @()
        } else {
            $rest = @($rest[$consumed..($rest.Count - 1)])
        }
    }

    if (-not (Test-FmBackendValid $script:TargetBackend)) { Exit-FmScript 1 }

    # Classify a from-firstmate -> secondmate request. Only a task selector
    # resolved through this home's meta whose authoritative kind is secondmate is
    # marked: the secondmate then routes its reply via the status path (see
    # fm-marker-lib.psm1). An explicit backend target (the escape hatch for
    # endpoints outside this home) and any crewmate/scout target are left
    # unmarked, and so is the --key path.
    $markFromFirstmate = $false
    $pendingReplyCorr = ''
    $pendingReplyCreated = $false
    $targetTaskId = ''
    if ($script:TargetSelector -and -not [string]::IsNullOrEmpty($script:TargetMeta) -and
        (Get-FmMetaValue $script:TargetMeta 'kind') -ceq 'secondmate') {
        $markFromFirstmate = $true
        $targetTaskId = Get-FmSendIdFromMeta -MetaPath $script:TargetMeta
    }

    # Validate the answerer-closes request before any durable mutation or send:
    # the target must have a task ledger in THIS home, the send must carry an
    # answer message, and every named key must be open right now in that ledger
    # per the ONE authoritative fold (Get-FmStatusOpenDecisions). Refusing here,
    # before the send, is what keeps a mistyped key loud instead of delivering an
    # answer that silently leaves its decision open.
    $resolveStatusFile = ''
    if ($resolveKeys.Count -gt 0) {
        if (-not $script:TargetSelector -or [string]::IsNullOrEmpty($script:TargetMeta)) {
            Write-FmErr ("error: --resolve-key needs a task selector resolved through this home's " +
                'metadata; an explicit backend target has no decision ledger here')
            Exit-FmScript 1
        }
        if ($rest.Count -ge 1 -and [string]$rest[0] -ceq '--key') {
            Write-FmErr 'error: --resolve-key cannot accompany --key; answering a decision requires a text answer'
            Exit-FmScript 1
        }
        # `[ -z "$*" ]` - the JOINED remainder, so `""` alone is empty but two
        # empty words are not (they join to one space).
        if (($rest -join ' ') -ceq '') {
            Write-FmErr 'error: --resolve-key requires a nonempty answer message'
            Exit-FmScript 1
        }
        $resolveTaskId = Get-FmSendIdFromMeta -MetaPath $script:TargetMeta
        # Composed in the caller's path spelling, because it is printed in both
        # the refusal and the manual close command (note 3 in the header).
        $resolveStatusFile = "$state/$resolveTaskId.status"
        $resolveOpenSet = Get-FmStatusOpenDecisions -Path $resolveStatusFile
        # A missing, unreadable or symlinked ledger folds to '' rather than
        # throwing; the guard keeps that true under StrictMode if the fold ever
        # returns $null, so an unreadable ledger refuses every key instead of
        # crashing mid-validation.
        if ($null -eq $resolveOpenSet) { $resolveOpenSet = '' }
        foreach ($resolveKey in $resolveKeys) {
            # `case "$resolve_open_set" in "$k"$'\t'*|*$'\n'"$k"$'\t'*`: the fold
            # emits "<key>\t<verb>\t<note>" records joined by LF, so a key is open
            # only at a record boundary - never as a substring of a note.
            $needle = "$resolveKey`t"
            if (-not ($resolveOpenSet.StartsWith($needle, [System.StringComparison]::Ordinal) -or
                    $resolveOpenSet.Contains("`n$needle", [System.StringComparison]::Ordinal))) {
                Write-FmErr ("error: --resolve-key '$resolveKey': no open decision or blocker with that key " +
                    "in $resolveStatusFile (already closed, mistyped, or transferred). Re-check the OPEN " +
                    'DECISIONS listing, then resend without that key or with the right one; nothing was sent.')
                Exit-FmScript 1
            }
        }
    }

    # Close each answered decision in this home's ledger, only after delivery is
    # fully confirmed. An append failure exits nonzero with the manual close
    # command; the decision then stays open and re-surfaces, never silently lost.
    function Close-FmSendResolvedKeys {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
            Justification = 'The plural is the contract and keeps the name greppable against its bash twin fm_send_close_resolved_keys: ONE send closes EVERY key it named, all-or-stop, and a singular name would read as close-one-key and hide that the loop is the unit of work.')]
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()]
            [System.Collections.Generic.List[string]]$Keys,
            [Parameter(Mandatory)][string]$StatusFile,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Answer,
            [Parameter(Mandatory)][string]$Target
        )
        # `tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177'`, in that order: the
        # three record-breaking whitespace bytes become SPACES (kept), and every
        # other C0/DEL control byte is DELETED. A status line is one record, so a
        # raw newline in the answer would forge a second one.
        $note = $Answer -creplace '[\n\r\t]', ' '
        $note = $note -creplace '[\x00-\x1f\x7f]', ''
        foreach ($key in $Keys) {
            $line = Limit-FmLine -Line "resolved [key=$key]: answered: $note"
            try {
                Add-FmFileLine -Path $StatusFile -Line $line
            } catch {
                Write-FmErr ("error: the answer was delivered to $Target, but decision key '$key' could not " +
                    "be closed in $StatusFile. Close it manually with: echo 'resolved [key=$key]: <how it " +
                    "was answered>' >> $StatusFile - do not resend the answer.")
                return $false
            }
        }
        return $true
    }

    # The target's harness came from its meta (recorded by fm-spawn), used only to
    # scope the codex `$<skill>` popup-settle below. A task selector carries meta;
    # an explicit backend-target escape hatch has none, so its harness is unknown
    # and treated as non-codex (the safe default that keeps the fast path).
    # Do not add a separate passive liveness preflight here. Active send paths own
    # backend readiness: herdr, for example, must route through its session-aware
    # target_ready path before sending, while zellij verifies pane labels in its
    # send implementation. A failed backend send is still surfaced below as a hard
    # error with the attempted resolution attached.

    if ($rest.Count -ge 1 -and [string]$rest[0] -ceq '--key') {
        # `case "$*" in *--resolve-key*)`: a substring test over the JOINED
        # remainder, so a --resolve-key TRAILING the key name is refused too
        # rather than being silently dropped as message words.
        if (($rest -join ' ').Contains('--resolve-key', [System.StringComparison]::Ordinal)) {
            Write-FmErr 'error: --resolve-key cannot accompany --key; answering a decision requires a text answer'
            Exit-FmScript 1
        }
        if ($rest.Count -lt 2) {
            Write-FmErr 'error: --key requires a key name'
            Exit-FmScript 1
        }
        $key = [string]$rest[1]
        # The RAW key is what the backend is asked for; only firstmate's own
        # follow-ups read the normalized form (see ConvertTo-FmSendSemanticKey).
        $semanticKey = ConvertTo-FmSendSemanticKey $key
        if (-not (Send-FmBackendKey -Backend $script:TargetBackend -Target $target -Key $key `
                    -ExpectedLabel $script:ExpectedLabel)) {
            Write-FmErr ("error: key '$key' not sent to $target ($($script:TargetBackend) send failed; " +
                "tried $($script:ResolutionTried))")
            Exit-FmScript 1
        }
        if (-not (Invoke-FmSendComposerClear -Key $semanticKey -Target $target)) { Exit-FmScript 1 }
        if (-not (Write-FmSendInterrupt -Key $semanticKey -Target $target)) { Exit-FmScript 1 }
        Exit-FmScript 0
    }

    # `MESSAGE=$*`: the remaining words joined with a single space.
    $message = ($rest -join ' ')
    # The pre-marker answer text, kept for the closing resolved note so the
    # durable ledger records the plain answer without marker or corr bytes.
    $resolveAnswerText = $message

    if ($markFromFirstmate) {
        # Reuse an existing correlation id for recovery resends; otherwise create
        # a durable parent expectation before delivery. Transport success never
        # resolves that expectation (see fm-pending-reply-lib.psm1).
        $existingCorr = Get-FmEnv 'FM_PENDING_REPLY_EXISTING_CORR'
        if ([string]::IsNullOrEmpty($existingCorr)) {
            $existingCorr = Get-FmPendingReplyCorr $message
        }
        if (-not [string]::IsNullOrEmpty($existingCorr) -and
            (Test-FmPendingReplyCorrReusable -State $state -CorrId $existingCorr -TaskId $targetTaskId)) {
            $pendingReplyCorr = $existingCorr
        } else {
            if ([string]::IsNullOrEmpty($targetTaskId)) {
                Write-FmErr 'error: cannot create pending-reply expectation without a resolvable secondmate task id'
                Exit-FmScript 1
            }
            $pendingReplyCorr = New-FmPendingReply -ParentHome $fmHome -State $state `
                -TaskId $targetTaskId -RequestText $message
            if ([string]::IsNullOrEmpty($pendingReplyCorr)) {
                Write-FmErr "error: failed to create parent pending-reply expectation for $targetTaskId"
                Exit-FmScript 1
            }
            $pendingReplyCreated = $true
        }
        $message = Add-FmPendingReplyCorr $message $pendingReplyCorr
        if ($pendingReplyCreated -and
            -not (Initialize-FmPendingReplyDelivery -State $state -CorrId $pendingReplyCorr)) {
            $null = Remove-FmPendingReplyUndelivered -State $state -CorrId $pendingReplyCorr
            Write-FmErr "error: failed to durably prepare pending-reply delivery for $targetTaskId"
            Exit-FmScript 1
        }
    }

    # Slash commands open a completion popup in some TUIs (verified on codex);
    # submitting too fast selects nothing, so give the popup time to settle before
    # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
    # invocation, so a `$...` message to a codex target gets the same settle. That
    # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
    # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
    # needlessly slow plain text to claude/opencode/pi. The target backend's
    # verified submit retry still backs the settle up either way.
    #
    # The subject is `$*` - the JOINED words - not the first argument, so a case
    # is decided by the message the target will actually receive.
    $settle = '0.3'
    if ($message.StartsWith('/')) {
        $settle = '1.2'
    } elseif ($message.StartsWith('$')) {
        if ($script:TargetHarness -ceq 'codex') { $settle = '1.2' }
    }
    $retries = Get-FmEnv 'FM_SEND_RETRIES' '3'
    $sleepS = Get-FmEnv 'FM_SEND_SLEEP' '0.4'

    # Type once, submit, verify. Only exact empty confirms delivery; every other
    # verdict preserves the loud refusal boundary. $null is the dispatcher's own
    # failure (unknown backend, adapter that would not load).
    $verdict = Send-FmBackendTextSubmit -Backend $script:TargetBackend -Target $target -Text $message `
        -Retries $retries -EnterSleep $sleepS -Settle $settle -ExpectedLabel $script:ExpectedLabel
    if ($null -eq $verdict) {
        if ($pendingReplyCreated -and -not [string]::IsNullOrEmpty($pendingReplyCorr)) {
            $null = Remove-FmPendingReplyUndelivered -State $state -CorrId $pendingReplyCorr
        }
        Write-FmErr ("error: text not sent to $target ($($script:TargetBackend) send failed; " +
            "tried $($script:ResolutionTried))")
        Exit-FmScript 1
    }
    if ($verdict -cne 'empty') {
        if ($pendingReplyCreated -and -not [string]::IsNullOrEmpty($pendingReplyCorr)) {
            $null = Remove-FmPendingReplyUndelivered -State $state -CorrId $pendingReplyCorr
        }
        if ($verdict -ceq 'send-failed') {
            Write-FmErr ("error: text not sent to $target ($($script:TargetBackend) send failed; " +
                "tried $($script:ResolutionTried))")
        } else {
            $shown = if ([string]::IsNullOrEmpty($verdict)) { 'unknown' } else { $verdict }
            Write-FmErr ("error: text not submitted to $target (delivery unconfirmed; verdict=$shown; " +
                "tried $($script:ResolutionTried))")
        }
        Exit-FmScript 1
    }

    # Delivery confirmed. Mark the pending expectation delivered without resolving
    # it: only a correlated parent report acknowledges the request.
    if (-not [string]::IsNullOrEmpty($pendingReplyCorr)) {
        $commit = Confirm-FmPendingReplyDelivery -State $state -CorrId $pendingReplyCorr
        if ($commit -ne 0) {
            if ($commit -eq 2) {
                Write-FmErr ("error: text was delivered to $target, but its pending-reply delivery commit " +
                    'failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend.')
            } else {
                Write-FmErr ("error: text was delivered to $target, but its pending-reply delivery commit " +
                    "and recovery marker both failed. Do not resend; inspect $state manually.")
            }
            Exit-FmScript 1
        }
    }

    # Delivery is fully confirmed: close each answered decision in this home's
    # ledger (answerer-closes; see the header contract).
    if ($resolveKeys.Count -gt 0) {
        if (-not (Close-FmSendResolvedKeys -Keys $resolveKeys -StatusFile $resolveStatusFile `
                    -Answer $resolveAnswerText -Target $target)) {
            Exit-FmScript 1
        }
    }

    # Submit landed with exact empty. Confirmation only proves the text was
    # accepted; the harness still needs a beat to spin up the turn before its busy
    # footer shows. Pause so an immediate peek catches the crewmate actually
    # working instead of the stale idle pane. FM_SEND_SETTLE=0 disables it. Scoped
    # to this path only, never the shared submit core.
    $sendSettle = Get-FmEnv 'FM_SEND_SETTLE' '1'
    if ($sendSettle -cne '0') {
        [double]$seconds = 0
        if ([double]::TryParse($sendSettle, [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and $seconds -gt 0) {
            Start-Sleep -Seconds $seconds
        }
    }
    Exit-FmScript 0
}
