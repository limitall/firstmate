# fm-pending-reply-lib.psm1 - parent-owned secondmate missed-report guards.
#
# Twin: bin/fm-pending-reply-lib.sh
#
# When the main firstmate delivers a marked from-firstmate request to a
# secondmate, this library records a durable parent-owned pending-reply
# expectation BEFORE delivery, embeds a privacy-safe correlation id in the
# outbound message, and later resolves that expectation only from a correlated
# parent status line or status-pointed document - never from transport success,
# chat content, or unrelated status activity.
#
# Safety property (captain direction 2026-07-22): a secondmate agent may ignore
# the marker and answer only in its visible conversation. The parent must notice
# the missing correlated report without scraping that conversation, send exactly
# one automatic recovery request asking for a repost through the parent channel,
# and escalate once if the recovery turn also completes without a correlated
# report. Never loop, never repeatedly inject, never silently expire unresolved
# records, and never treat wrong-home or structured-home heuristics as
# acknowledgement.
#
# Record location (parent FM_HOME): state/pending-replies/<corr_id>, a key=value
# file whose schema the bash twin's header enumerates field by field; it is not
# duplicated here because that header remains the owner and a second copy would
# drift. Phases: awaiting_report | delivery_unknown | recovery_sending |
# recovery_sent | recovery_failed | recovery_unknown | escalated | resolved.
#
# No side effects on import. Tunables (env), all honored identically:
#   FM_PENDING_REPLY_GRACE_SECS   default 120
#   FM_PENDING_REPLY_DIR_OVERRIDE override the pending-replies directory (tests)
#   FM_PENDING_REPLY_SEND_HOOK    optional command template for recovery delivery
#   FM_PENDING_REPLY_NOW          optional fixed epoch for deterministic tests
#
# bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-pending-reply-lib.sh                    this file
#   --------------------------------------------   ---------------------------------------
#   FM_PENDING_REPLY_SCHEMA                        Get-FmPendingReplySchema
#   FM_PENDING_REPLY_CORR_RE                       Get-FmPendingReplyCorrRegex
#   FM_PENDING_REPLY_GRACE_DEFAULT                 Get-FmPendingReplyGraceDefault
#   fm_pending_reply_now                           Get-FmPendingReplyNow
#   fm_pending_reply_grace_secs                    Get-FmPendingReplyGraceSec
#   fm_pending_reply_dir                           Get-FmPendingReplyDir
#   fm_pending_reply_path                          Get-FmPendingReplyPath
#   fm_pending_reply_new_id                        New-FmPendingReplyId
#   fm_pending_reply_corr_token                    Get-FmPendingReplyCorrToken
#   fm_pending_reply_extract_corr                  Get-FmPendingReplyCorr
#   fm_pending_reply_text_has_corr                 Test-FmPendingReplyTextHasCorr
#   fm_pending_reply_summarize                     Get-FmPendingReplySummary
#   fm_pending_reply_get                           Get-FmPendingReplyValue
#   fm_pending_reply_set                           Set-FmPendingReplyValue
#   fm_pending_reply_corr_reusable                 Test-FmPendingReplyCorrReusable
#   fm_pending_reply_embed_corr                    Add-FmPendingReplyCorr
#   fm_pending_reply_create                        New-FmPendingReply
#   fm_pending_reply_mark_delivered                Set-FmPendingReplyDelivered
#   fm_pending_reply_delivery_confirmation_path    Get-FmPendingReplyConfirmationPath
#   fm_pending_reply_write_delivery_confirmation   Write-FmPendingReplyConfirmation
#   fm_pending_reply_prepare_delivery              Initialize-FmPendingReplyDelivery
#   fm_pending_reply_confirm_delivery              Confirm-FmPendingReplyDelivery
#   fm_pending_reply_reconcile_delivery            Sync-FmPendingReplyDelivery
#   fm_pending_reply_discard_undelivered           Remove-FmPendingReplyUndelivered
#   fm_pending_reply_line_resolves                 Test-FmPendingReplyResolvingLine
#   fm_pending_reply_find_resolve_line             Find-FmPendingReplyResolveLine
#   fm_pending_reply_file_signature                Get-FmPendingReplyFileSignature
#   fm_pending_reply_status_set_signature          Get-FmPendingReplyStatusSetSignature
#   fm_pending_reply_resolve_via_of_line           Get-FmPendingReplyResolveVia
#   fm_pending_reply_try_resolve                   Resolve-FmPendingReply
#   fm_pending_reply_observe_busy                  Write-FmPendingReplyBusyObservation
#   fm_pending_reply_fallback_idle_eligible        Test-FmPendingReplyFallbackIdleEligible
#   fm_pending_reply_backend_observation           Get-FmPendingReplyBackendObservation
#   fm_pending_reply_busy_state_from_observation   Get-FmPendingReplyBusyState
#   fm_pending_reply_mark_turn_completed           Set-FmPendingReplyTurnCompleted
#   fm_pending_reply_recovery_message              Get-FmPendingReplyRecoveryMessage
#   fm_pending_reply_send_recovery                 Send-FmPendingReplyRecovery
#   fm_pending_reply_pid_identity                  Get-FmPendingReplyPidIdentity
#   fm_pending_reply_sender_alive                  Test-FmPendingReplySenderAlive
#   fm_pending_reply_finish_recovery               Complete-FmPendingReplyRecovery
#   fm_pending_reply_reconcile_recovery            Sync-FmPendingReplyRecovery
#   fm_pending_reply_maybe_escalate                Invoke-FmPendingReplyEscalation
#   fm_pending_reply_detect_wrong_home             Find-FmPendingReplyWrongHome
#   fm_pending_reply_tick_one                      Update-FmPendingReplyRecord
#   fm_pending_reply_tick                          Update-FmPendingReply
#   fm_pending_reply_task_has_open                 Test-FmPendingReplyTaskHasOpen
#
# ============================================================================
# 1. TWO DIGESTS THAT MUST BE BYTE-IDENTICAL ACROSS THE TWO WORLDS
# ============================================================================
# Both land in DURABLE RECORD FIELDS that the other language later compares, so
# a mismatch is not cosmetic: it makes every tick believe the scanned set
# changed, re-scan, and rewrite the record forever.
#
#   parent_status_scan_signature  <- Get-FmPendingReplyFileSignature
#   wrong_home_scan_signature     <- Get-FmPendingReplyStatusSetSignature
#   wrong_home_sightings          <- the same cksum, per sighting
#
# Both were verified against the bash oracle on this host BEFORE this file was
# written, rather than assumed:
#
#   stat -c '%d:%i:%s:%Y:%Z'  1324268815:26740122787919119:9:1785984852:1785984852
#   this module               1324268815:26740122787919119:9:1785984852:1785984852
#
#   POSIX cksum, six inputs, all exact:
#     ""  -> 4294967295 0        "a"           -> 1220704766 1
#     "abc" -> 1219131554 3      "hello world" -> 1135714720 11
#     "x:y:z" -> 4113885327 5    "aaa.status\nbbb.status\n" -> 2612439692 22
#
# The cksum CRC is NOT the common CRC-32: it is poly 0x04C11DB7 MSB-first with
# init 0, then the LENGTH folded in base-256 low-byte-first, then complemented.
# The empty input hashing to 0xFFFFFFFF is the tell that the length step and the
# final complement are both present.
#
# The stat fields come from one GetFileInformationByHandle call: MSYS `%d` is
# dwVolumeSerialNumber and MSYS `%i` is (IndexHigh<<32)|IndexLow, both verified
# equal above. `%Y` is LastWriteTimeUtc and `%Z` maps to CreationTimeUtc here;
# the fixture that proved it had them equal, so a file whose two stamps DIFFER
# is asserted in the suite rather than trusted.
#
# ============================================================================
# 2. THE DELIBERATE pid-identity DUPLICATE
# ============================================================================
# Get-FmPendingReplyPidIdentity duplicates bin/fm-wake-lib.psm1's
# Get-FmPidIdentity instead of importing it, exactly as the bash twin duplicates
# fm_pid_identity and says why: fm-wake-lib CREATES ITS STATE DIRECTORY ON LOAD,
# and this library must stay side-effect-free. That is true of the .psm1 too
# (Initialize-FmWakeContext runs at import), so importing it here would break the
# same contract. bin/fm-psproc-lib.psm1 has no identity function to borrow.
#
# Structural sharing is therefore unavailable, so the mitigation is the one the
# -Force finding taught: make DRIFT A TEST FAILURE rather than preventing it
# structurally. tests/fm-marker-session-psm1.test.sh asserts this function is
# byte-identical to Get-FmPidIdentity under a shared FM_PROC_ROOT_OVERRIDE.
#
# Two divergences are correct and are asserted rather than papered over:
#   * wake-lib emits `linux-starttime=` on Linux where the pending-reply twin
#     always emits `proc-starttime=` - the bash pair differs the same way.
#   * on Windows with no /proc override, the bash twin cannot answer at all
#     (Cygwin ps rejects the -o fields) while this one emits `win-starttime=`.
#     A cross-world comparison then MISMATCHES, which is right: the two worlds
#     hold different pid spaces, so "not the same sender" is the true answer,
#     and Test-FmPendingReplySenderAlive returning false routes to
#     recovery_unknown - escalate, never assume a live sender.
#
# ============================================================================
# 3. RETURN SHAPES
# ============================================================================
#   predicate (return 0/1)   -> [bool]
#   prints a value           -> the value, minus the trailing newline `$( )`
#                               would have stripped
#   three-way status (0/1/2) -> [int], documented per function
#   "did it work"            -> [bool], where the bash twin's only signal was
#                               its exit status
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-pending-reply-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports (docs/powershell-port.md). The list mirrors the
# bash twin's three source lines; fm-marker-lib carries the operational-input
# surface, exactly as it does for the bash twin.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-marker-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tmux-lib.psm1')

$script:FmPrOrdinal = [System.StringComparison]::Ordinal
$script:FmPrUtf8 = [System.Text.UTF8Encoding]::new($false, $false)

# --- constants ----------------------------------------------------------------

<#
.SYNOPSIS
The durable record schema token (FM_PENDING_REPLY_SCHEMA).
#>
function Get-FmPendingReplySchema {
    [CmdletBinding()][OutputType([string])] param()
    return 'fm-pending-reply.v1'
}

<#
.SYNOPSIS
The correlation-token pattern (FM_PENDING_REPLY_CORR_RE).
#>
function Get-FmPendingReplyCorrRegex {
    [CmdletBinding()][OutputType([string])] param()
    return 'corr=[A-Fa-f0-9]{16}'
}

<#
.SYNOPSIS
The default grace window in seconds (FM_PENDING_REPLY_GRACE_DEFAULT).
#>
function Get-FmPendingReplyGraceDefault {
    [CmdletBinding()][OutputType([int])] param()
    return 120
}

<#
.SYNOPSIS
Current epoch seconds, or the FM_PENDING_REPLY_NOW override.
.DESCRIPTION
Twin of fm_pending_reply_now. The override is `-n` (set and NON-empty), not
`:-`, so an exported empty value falls through to the clock exactly as bash does.
#>
function Get-FmPendingReplyNow {
    [CmdletBinding()][OutputType([string])] param()
    $fixed = Get-FmEnv -Name 'FM_PENDING_REPLY_NOW'
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

<#
.SYNOPSIS
The bounded grace window before recovery is eligible.
.DESCRIPTION
Twin of fm_pending_reply_grace_secs: a non-numeric or empty override falls back
to the default rather than propagating garbage into an arithmetic comparison.
#>
function Get-FmPendingReplyGraceSec {
    [CmdletBinding()][OutputType([string])] param()
    $g = Get-FmEnv -Name 'FM_PENDING_REPLY_GRACE_SECS' -Default ([string](Get-FmPendingReplyGraceDefault))
    if ($g -notmatch '^[0-9]+$') { $g = [string](Get-FmPendingReplyGraceDefault) }
    return $g
}

# --- record locations ---------------------------------------------------------

<#
.SYNOPSIS
The directory holding durable pending-reply records for <State>.
#>
function Get-FmPendingReplyDir {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    $override = Get-FmEnv -Name 'FM_PENDING_REPLY_DIR_OVERRIDE'
    if (-not [string]::IsNullOrEmpty($override)) { return $override }
    return "$State/pending-replies"
}

<#
.SYNOPSIS
The durable record path for one correlation id.
#>
function Get-FmPendingReplyPath {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    return "$(Get-FmPendingReplyDir $State)/$CorrId"
}

# --- correlation ids ----------------------------------------------------------

<#
.SYNOPSIS
A privacy-safe correlation id: 16 lowercase hex characters (64 bits).
.DESCRIPTION
Twin of fm_pending_reply_new_id. The bash twin prefers `openssl rand -hex 8` and
falls back to a cksum/shasum mash of pid, nanosecond clock and $RANDOM when
openssl is absent. .NET's cryptographic RNG is always present and is strictly
better than either, so the external dependency and its fallback DISAPPEAR - the
one deliberate simplification in this file, and it is safe because the id's only
contract is "16 lowercase hex characters, unpredictable, unique in practice",
which the suite asserts by shape rather than by algorithm.
#>
function New-FmPendingReplyId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'New- is the natural verb for a generator and keeps the pairing with fm_pending_reply_new_id obvious, but this one only draws 8 random bytes and formats them; it touches nothing outside its own scope. SupportsShouldProcess would be a lie - under -WhatIf it would return nothing and the caller would create a record with an empty correlation id.')]
    [CmdletBinding()][OutputType([string])] param()
    $bytes = [byte[]]::new(8)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $sb = [System.Text.StringBuilder]::new(16)
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

<#
.SYNOPSIS
The wire token for a correlation id: `corr=<id>`.
#>
function Get-FmPendingReplyCorrToken {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$CorrId)
    return "corr=$CorrId"
}

<#
.SYNOPSIS
The first corr=<16hex> token in free text, lowercased, or '' when absent.
.DESCRIPTION
Twin of fm_pending_reply_extract_corr. Case-SENSITIVE matching on the pattern's
own [A-Fa-f0-9] class, then lowercased with an INVARIANT fold: bash's
`tr 'A-F' 'a-f'` is byte-wise, and a culture-sensitive ToLower would map the
Turkish dotted I differently and could corrupt a hex digit's neighbours.
#>
function Get-FmPendingReplyCorr {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $m = [regex]::Match($Text, (Get-FmPendingReplyCorrRegex))
    if (-not $m.Success) { return '' }
    return $m.Value.Substring('corr='.Length).ToLowerInvariant()
}

<#
.SYNOPSIS
True when <Text> carries the exact correlation token for <CorrId>.
.DESCRIPTION
Twin of fm_pending_reply_text_has_corr, which is a bash `case` SUBSTRING test -
not a regex - so it is reproduced as an ordinal IndexOf rather than a match.
#>
function Test-FmPendingReplyTextHasCorr {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $token = Get-FmPendingReplyCorrToken $CorrId
    return ($Text.IndexOf($token, $script:FmPrOrdinal) -ge 0)
}

<#
.SYNOPSIS
A single-line, bounded, control-character-free request summary.
.DESCRIPTION
Twin of fm_pending_reply_summarize:

    tr '\t\r\n' '   '                 TAB/CR/LF each become one space
    tr -cd '\11\12\15\40-\176'        keep only TAB/LF/CR and printable ASCII
    sed 's/^[[:space:]]*//;s/...$//'  trim both ends
    drop a leading marker, then a leading corr= token
    cap at 120 characters, with "..." replacing the tail

The `tr -cd` COMPLEMENT is why this is not a `\s` job: it deletes every byte
outside printable ASCII, so a UTF-8 summary is stripped to its ASCII skeleton in
BOTH worlds. Reproducing that faithfully means filtering by CODE POINT and
rejecting anything above 0x7E - a "kinder" version that preserved accents would
write a different durable summary than bash and change the recovery message.
#>
function Get-FmPendingReplySummary {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # tr '\t\r\n' '   '
    $s = [regex]::Replace($Text, '[\x09\x0A\x0D]', ' ')
    # tr -cd '\11\12\15\40-\176' - after the translation above no TAB/LF/CR
    # survives, so this reduces to "printable ASCII only".
    $sb = [System.Text.StringBuilder]::new($s.Length)
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 9 -or $c -eq 10 -or $c -eq 13 -or ($c -ge 32 -and $c -le 126)) {
            [void]$sb.Append($ch)
        }
    }
    $cleaned = $sb.ToString()
    # sed trim: [[:space:]] at either end.
    $cleaned = [regex]::Replace($cleaned, '^\s+|\s+$', '')
    # Drop an already-present marker prefix so the durable summary stays short.
    $mark = Get-FmOperationalConstant 'FM_FROMFIRST_MARK'
    if (-not [string]::IsNullOrEmpty($mark) -and $cleaned.StartsWith($mark, $script:FmPrOrdinal)) {
        $cleaned = $cleaned.Substring($mark.Length)
    }
    $cleaned = [regex]::Replace($cleaned, '^corr=[A-Fa-f0-9]{16}[\s]*', '')
    if ($cleaned.Length -gt 120) { $cleaned = $cleaned.Substring(0, 117) + '...' }
    return $cleaned
}

# --- atomic publish -----------------------------------------------------------
#
# A LOCAL stand-in for fm-common's Set-FmFileTextAtomic, for the same reason
# bin/fm-x-lib.psm1 carries Set-FmxFileTextAtomic: that helper is broken for a
# write over an EXISTING file. Measured here - a fresh write returns $true and a
# rewrite of the same path returns $false - because it passes $null as
# File.Replace's backup-path argument, which binds as "" and throws.
#
# That defect would disable essentially this whole state machine, since every
# phase transition rewrites an existing record through Set-FmPendingReplyValue.
# [System.IO.File]::Move(src, dest, overwrite: $true) is the same same-volume
# atomic rename without the backup argument. Reported to the fm-common owner;
# when the one-token fix lands, this can delegate again.
function Set-FmPendingReplyFileAtomic {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin publishes records unconditionally through mktemp plus mv -f; a -WhatIf/-Confirm surface would diverge from the twin and could strand a pending expectation.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )
    $native = ConvertTo-FmNativePath $Path
    $dir = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
    $leaf = [System.IO.Path]::GetFileName($native)
    # The temp is a SIBLING so the rename stays same-volume and therefore atomic,
    # and it is dot-prefixed so a concurrent record scan skips it.
    $temp = Join-Path $dir (".{0}.fm-pr.{1}" -f $leaf, ([System.IO.Path]::GetRandomFileName()))
    try {
        $body = ([string]$Text) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($temp, $body, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $native, $true)
        return $true
    } catch {
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
        return $false
    }
}

# --- record read / write ------------------------------------------------------

<#
.SYNOPSIS
Read one key from a pending-reply record; '' when absent.
.DESCRIPTION
Twin of fm_pending_reply_get:

    grep "^${key}=" "$rec" | tail -1 | cut -d= -f2-

so the LAST matching line wins and the value is everything after the FIRST '='.
`grep` here is a BASIC regex on an unescaped key, matching the bash twin, and
every caller passes a literal field name.
#>
function Get-FmPendingReplyValue {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Key
    )
    $native = ConvertTo-FmNativePath $RecordPath
    if (-not [System.IO.File]::Exists($native)) { return '' }
    $prefix = "$Key="
    $value = ''
    foreach ($line in (Get-FmFileLines $native)) {
        if ($line.StartsWith($prefix, $script:FmPrOrdinal)) {
            $value = $line.Substring($prefix.Length)
        }
    }
    return $value
}

<#
.SYNOPSIS
Rewrite one key in a record atomically, preserving every other key. Returns
$true on success.
.DESCRIPTION
Twin of fm_pending_reply_set. The bash twin drops EVERY line matching the key
and appends the new value at the END, so a rewritten key moves to the bottom of
the record; that ordering is reproduced because the suite compares whole records
between the two worlds. The temp file is a sibling so the rename stays
same-volume and therefore atomic.
#>
function Set-FmPendingReplyValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin rewrites the record unconditionally on a watcher hot path; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Key,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Value = ''
    )
    $native = ConvertTo-FmNativePath $RecordPath
    if (-not [System.IO.File]::Exists($native)) { return $false }
    $prefix = "$Key="
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in (Get-FmFileLines $native)) {
        if ($line.StartsWith($prefix, $script:FmPrOrdinal)) { continue }
        [void]$sb.Append($line).Append("`n")
    }
    [void]$sb.Append($prefix).Append([string]$Value).Append("`n")
    return (Set-FmPendingReplyFileAtomic -Path $native -Text $sb.ToString())
}

<#
.SYNOPSIS
True when an existing correlation id may be reused for this task.
.DESCRIPTION
Twin of fm_pending_reply_corr_reusable: the id must be exactly 16 hex
characters, the record must exist, its task must match, and its phase must be
one that is still expecting a report.
#>
function Test-FmPendingReplyCorrReusable {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$TaskId
    )
    if ([string]::IsNullOrEmpty($CorrId)) { return $false }
    if (-not [regex]::IsMatch($CorrId, '^[A-Fa-f0-9]{16}$')) { return $false }
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if (-not [string]::Equals((Get-FmPendingReplyValue $rec 'task_id'), [string]$TaskId, $script:FmPrOrdinal)) {
        return $false
    }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    return ($phase -cin @('awaiting_report', 'recovery_sending', 'recovery_sent'))
}

<#
.SYNOPSIS
Embed or replace a correlation token after the from-firstmate marker.
.DESCRIPTION
Twin of fm_pending_reply_embed_corr, which assigns through a caller-named
variable because a bash `$( )` would STRIP THE TRAILING NEWLINES of the request
body. PowerShell has no such stripping, so this returns the string directly -
and the suite asserts the trailing-newline preservation the bash twin's comment
exists to protect.

Idempotent for the same corr, and replaces a DIFFERENT leading corr token: the
21-character window is `corr=` plus 16 hex, and only space/tab after it are
consumed, never a newline that belongs to the body.
#>
function Add-FmPendingReplyCorr {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $token = Get-FmPendingReplyCorrToken $CorrId
    $mark = Get-FmOperationalConstant 'FM_FROMFIRST_MARK'
    $marked = Add-FmFromFirstmateMark ([string]$Message)
    $body = $marked
    if ($body.StartsWith($mark, $script:FmPrOrdinal)) { $body = $body.Substring($mark.Length) }

    if ($body.Length -ge 21) {
        $existing = $body.Substring(0, 21)
        if ([regex]::IsMatch($existing, '^corr=[a-fA-F0-9]{16}$')) {
            $body = $body.Substring(21)
            # Space and TAB only - a leading newline is body content.
            $i = 0
            while ($i -lt $body.Length -and ($body[$i] -eq ' ' -or $body[$i] -eq "`t")) { $i++ }
            if ($i -gt 0) { $body = $body.Substring($i) }
        }
    }
    return "$mark$token $body"
}

# --- creation -----------------------------------------------------------------

<#
.SYNOPSIS
Create a durable pending-reply expectation; returns the corr id, or $null.
.DESCRIPTION
Twin of fm_pending_reply_create. Delivers nothing: the expectation exists BEFORE
delivery so a send that never lands still leaves a record to reconcile.

The record body is written in the bash twin's exact field ORDER, because the
suite compares whole records across the two worlds. mode 0700/0600 is requested
and ignored on this host (`noacl`), exactly as in bash - see the port doc's
"Things that must NOT be improved"; this module does not substitute an ACL.
#>
function New-FmPendingReply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin creates the record unconditionally as part of a send; a -WhatIf/-Confirm surface would diverge from the twin and could strand a delivery with no expectation.')]
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ParentHome,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$TaskId,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$RequestText
    )
    if ([string]::IsNullOrEmpty($ParentHome) -or [string]::IsNullOrEmpty($State) -or
        [string]::IsNullOrEmpty($TaskId)) {
        return $null
    }
    $dir = Get-FmPendingReplyDir $State
    try { [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $dir)) } catch { return $null }

    $corr = New-FmPendingReplyId
    if ($corr.Length -ne 16) { return $null }
    $rec = Get-FmPendingReplyPath $State $corr
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath $rec)) {
        $corr = New-FmPendingReplyId
        $rec = Get-FmPendingReplyPath $State $corr
        if (Test-Path -LiteralPath (ConvertTo-FmNativePath $rec)) { return $null }
    }

    $now = Get-FmPendingReplyNow
    $summary = Get-FmPendingReplySummary $RequestText
    $statusPath = "$State/$TaskId.status"

    $sb = [System.Text.StringBuilder]::new()
    foreach ($pair in @(
        @('schema', (Get-FmPendingReplySchema)), @('corr_id', $corr), @('task_id', $TaskId),
        @('parent_home', $ParentHome), @('parent_status', $statusPath),
        @('parent_status_scan_signature', ''), @('request_summary', $summary),
        @('created_epoch', $now), @('delivered_epoch', ''), @('phase', 'awaiting_report'),
        @('turn_seen_busy', '0'), @('request_turn_completed_epoch', ''),
        @('recovery_attempted_epoch', ''), @('recovery_sender_pid', ''),
        @('recovery_sender_identity', ''), @('recovery_sent_epoch', ''),
        @('recovery_delivery_outcome', ''), @('recovery_turn_seen_busy', '0'),
        @('recovery_turn_completed_epoch', ''), @('escalated_epoch', ''),
        @('resolved_epoch', ''), @('resolved_via', ''), @('wrong_home_hits', '0'),
        @('wrong_home_sightings', ''), @('wrong_home_scan_signature', ''),
        @('grace_secs', (Get-FmPendingReplyGraceSec)))) {
        [void]$sb.Append($pair[0]).Append('=').Append([string]$pair[1]).Append("`n")
    }
    if (-not (Set-FmPendingReplyFileAtomic -Path $rec -Text $sb.ToString())) { return $null }
    return $corr
}

# --- delivery -----------------------------------------------------------------

<#
.SYNOPSIS
Mark delivery success for an existing expectation. NEVER resolves it.
.DESCRIPTION
Twin of fm_pending_reply_mark_delivered. Delivery is not acknowledgement: the
whole point of this library is that transport success proves nothing about
whether the secondmate reported back.
#>
function Set-FmPendingReplyDelivered {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin records delivery unconditionally on the send path; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ConfirmedEpoch
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ($phase -cnotin @('awaiting_report', 'delivery_unknown', 'recovery_sending',
                         'recovery_sent', 'escalated', 'resolved')) {
        return $false
    }
    $delivered = Get-FmPendingReplyValue $rec 'delivered_epoch'
    if ([string]::IsNullOrEmpty($delivered)) {
        # `${confirmed_epoch:-$(now)}` - an EMPTY argument falls back to now.
        $now = if ([string]::IsNullOrEmpty($ConfirmedEpoch)) { Get-FmPendingReplyNow } else { $ConfirmedEpoch }
        if (-not (Set-FmPendingReplyValue $rec 'delivered_epoch' $now)) { return $false }
    }
    if ([string]::Equals($phase, 'delivery_unknown', $script:FmPrOrdinal)) {
        if (-not (Set-FmPendingReplyValue $rec 'phase' 'awaiting_report')) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
The sidecar path recording an in-flight delivery attempt.
#>
function Get-FmPendingReplyConfirmationPath {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    return "$(Get-FmPendingReplyDir $State)/.delivery-confirmed-$CorrId"
}

<#
.SYNOPSIS
Publish a delivery-confirmation sidecar atomically.
#>
function Write-FmPendingReplyConfirmation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes the sidecar unconditionally around a send; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$DeliveryState,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][AllowNull()][string]$Value
    )
    $marker = Get-FmPendingReplyConfirmationPath $State $CorrId
    $dir = [System.IO.Path]::GetDirectoryName((ConvertTo-FmNativePath $marker))
    try { [void][System.IO.Directory]::CreateDirectory($dir) } catch { return $false }
    return (Set-FmPendingReplyFileAtomic -Path $marker -Text "$DeliveryState=$Value`n")
}

<#
.SYNOPSIS
Record that a delivery attempt is starting. Idempotent.
.DESCRIPTION
Twin of fm_pending_reply_prepare_delivery. Already-delivered records and an
existing sidecar are both no-op successes, so a retried send cannot reset the
attempt clock the unknown-delivery escalation measures against.
#>
function Initialize-FmPendingReplyDelivery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin prepares delivery unconditionally on the send path; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if (-not [string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) { return $true }
    $marker = Get-FmPendingReplyConfirmationPath $State $CorrId
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $marker))) { return $true }
    return (Write-FmPendingReplyConfirmation $State $CorrId 'attempted' (Get-FmPendingReplyNow))
}

<#
.SYNOPSIS
Confirm a delivery. Returns 0 on success, 1 when preparation failed, 2 when the
confirmation landed but the record could not be marked.
.DESCRIPTION
Twin of fm_pending_reply_confirm_delivery, whose THREE exit codes callers branch
on, so the int is kept rather than flattened to a bool.
#>
function Confirm-FmPendingReplyDelivery {
    [CmdletBinding()][OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $marker = Get-FmPendingReplyConfirmationPath $State $CorrId
    if (-not (Initialize-FmPendingReplyDelivery $State $CorrId)) { return 1 }
    $now = Get-FmPendingReplyNow
    if (-not (Write-FmPendingReplyConfirmation $State $CorrId 'confirmed' $now)) { return 1 }
    if (Set-FmPendingReplyDelivered $State $CorrId $now) {
        Remove-FmPendingReplyFile $marker
        return 0
    }
    return 2
}

# `rm -f ... 2>/dev/null || true` - a removal that cannot happen is never fatal.
function Remove-FmPendingReplyFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin removes best-effort with every failure discarded; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()] param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        $native = ConvertTo-FmNativePath $Path
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch { $null = $_ }
}

<#
.SYNOPSIS
Reconcile a delivery whose outcome was lost. Returns $true when it settled.
.DESCRIPTION
Twin of fm_pending_reply_reconcile_delivery. A `confirmed` sidecar marks the
record delivered; an `attempted` sidecar older than the grace window moves the
phase to delivery_unknown, which is what later escalates. A crash between the
post and its receipt is the case this exists for, and guessing is exactly what
it must not do.
#>
function Sync-FmPendingReplyDelivery {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    $marker = Get-FmPendingReplyConfirmationPath $State $CorrId
    $delivered = Get-FmPendingReplyValue $rec 'delivered_epoch'
    if (-not [string]::IsNullOrEmpty($delivered)) {
        Remove-FmPendingReplyFile $marker
        return $true
    }
    $nativeMarker = ConvertTo-FmNativePath $marker
    if (-not [System.IO.File]::Exists($nativeMarker)) { return $false }
    $entry = (Get-FmFileText $nativeMarker).TrimEnd("`n")
    $eq = $entry.IndexOf('=')
    $deliveryState = if ($eq -ge 0) { $entry.Substring(0, $eq) } else { $entry }
    $value = if ($eq -ge 0) { $entry.Substring($eq + 1) } else { $entry }

    if ([string]::Equals($deliveryState, 'confirmed', $script:FmPrOrdinal)) {
        if ($value -notmatch '^[0-9]+$') { return $false }
        if (-not (Set-FmPendingReplyDelivered $State $CorrId $value)) { return $false }
        Remove-FmPendingReplyFile $marker
        return $true
    }
    if ([string]::Equals($deliveryState, 'attempted', $script:FmPrOrdinal)) {
        if ($value -notmatch '^[0-9]+$') { return $false }
        $grace = Get-FmPendingReplyValue $rec 'grace_secs'
        if ($grace -notmatch '^[0-9]+$') { $grace = Get-FmPendingReplyGraceSec }
        $now = Get-FmPendingReplyNow
        if (([long]$now - [long]$value) -lt [long]$grace) { return $false }
        if (-not [string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'awaiting_report', $script:FmPrOrdinal)) {
            return $false
        }
        return (Set-FmPendingReplyValue $rec 'phase' 'delivery_unknown')
    }
    return $false
}

<#
.SYNOPSIS
Drop an UNDELIVERED expectation after a failed send. Returns $true when gone.
.DESCRIPTION
Twin of fm_pending_reply_discard_undelivered: a transport failure must not
masquerade as a missed report later. Refuses once delivery is recorded.
#>
function Remove-FmPendingReplyUndelivered {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin discards unconditionally after a failed send; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $true }
    if (-not [string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) { return $false }
    Remove-FmPendingReplyFile (Get-FmPendingReplyConfirmationPath $State $CorrId)
    Remove-FmPendingReplyFile $rec
    return $true
}

# --- resolution ---------------------------------------------------------------

<#
.SYNOPSIS
True when a status line is a correlated acknowledgement for <CorrId>.
.DESCRIPTION
Twin of fm_pending_reply_line_resolves. The parent's OWN escalation line must
not self-resolve: it names the request with pending-reply-id= rather than corr=,
and any line containing "pending-reply-missed" is refused outright.
#>
function Test-FmPendingReplyResolvingLine {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    if ([string]::IsNullOrEmpty($Line) -or [string]::IsNullOrEmpty($CorrId)) { return $false }
    if ($Line.IndexOf('pending-reply-missed', $script:FmPrOrdinal) -ge 0) { return $false }
    return (Test-FmPendingReplyTextHasCorr $Line $CorrId)
}

<#
.SYNOPSIS
The first correlated resolve line in a status file, or ''.
#>
function Find-FmPendingReplyResolveLine {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$StatusFile,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    if ([string]::IsNullOrEmpty($StatusFile)) { return '' }
    $native = ConvertTo-FmNativePath $StatusFile
    if (-not [System.IO.File]::Exists($native)) { return '' }
    foreach ($line in (Get-FmFileLines $native)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if (Test-FmPendingReplyResolvingLine $line $CorrId) { return $line }
    }
    return ''
}

<#
.SYNOPSIS
The `stat -c '%d:%i:%s:%Y:%Z'` signature of one file.
.DESCRIPTION
Twin of fm_pending_reply_file_signature: device:inode:size:mtime:ctime, or the
literal `missing` / `unreadable`. Header note 1 records the measurement proving
all five fields agree with MSYS stat on this host.
#>
function Get-FmPendingReplyFileSignature {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return 'missing' }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return 'missing' }
    try {
        $id = Get-FmPendingReplyFileIdentity -Path $native
        if ($null -eq $id) { return 'unreadable' }
        $fi = [System.IO.FileInfo]::new($native)
        $mtime = [DateTimeOffset]::new($fi.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
        # `%Z` is st_ctime - the CHANGE time, not the creation time. MSYS derives
        # it from LastWriteTime on this filesystem, MEASURED rather than assumed:
        # a fresh file has all three stamps equal and cannot distinguish them, but
        # after an append bash reported %Z = 1785992128 (= mtime) while the
        # creation stamp was still 1785992121. An earlier draft used
        # CreationTimeUtc and this suite caught it.
        #
        # The one input that could still separate them is a metadata-only change,
        # which updates NTFS ChangeTime but not LastWriteTime. chmod is inert on
        # this host (`noacl`), so that case is unreachable in practice, and the
        # signature is a CHANGE DETECTOR whose failure direction is one extra
        # scan.
        $ctime = $mtime
        return ('{0}:{1}:{2}:{3}:{4}' -f $id.Device, $id.Inode, $fi.Length, $mtime, $ctime)
    } catch {
        return 'unreadable'
    }
}

<#
.SYNOPSIS
A stable digest over every *.status file in a directory.
.DESCRIPTION
Twin of fm_pending_reply_status_set_signature: for each *.status in GLOB order,
emit `<len>:<path>:<signature>` and one LF, then run the whole stream through
POSIX cksum and render `<crc>-<bytes>`.

The PATH is part of the hashed bytes and the two worlds spell it differently, so
this digest is deliberately NOT comparable across worlds for the same directory.
That is correct and harmless: it is a CHANGE DETECTOR compared only against the
value the same world previously stored, and a first-pass mismatch costs one
extra scan, never a missed report. The suite asserts the cksum itself against
the bash oracle on identical BYTES, which is the part that must agree.
#>
function Get-FmPendingReplyStatusSetSignature {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$StatusDir)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($path in (Get-FmPendingReplyStatusFile -Directory $StatusDir)) {
        $sig = Get-FmPendingReplyFileSignature $path
        [void]$sb.Append($path.Length).Append(':').Append($path).Append(':').Append($sig).Append("`n")
    }
    return (Get-FmPendingReplyCksum -Text $sb.ToString())
}

# The `"$dir"/*.status` glob twin: full paths, ordinal-sorted, dotfiles excluded
# because a bash `*` never matches a leading dot.
function Get-FmPendingReplyStatusFile {
    [CmdletBinding()][OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return @() }
    $native = ConvertTo-FmNativePath $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    $out = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', $script:FmPrOrdinal)) { continue }
            if (-not $name.EndsWith('.status', $script:FmPrOrdinal)) { continue }
            if ($name.Length -le '.status'.Length) { continue }
            if (-not [System.IO.File]::Exists($entry)) { continue }
            $out.Add("$Directory/$name")
        }
    } catch {
        return @()
    }
    $sorted = [string[]]$out.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

<#
.SYNOPSIS
Classify how a resolving line acknowledged the request.
.DESCRIPTION
Twin of fm_pending_reply_resolve_via_of_line, in the bash `case` ARM ORDER,
which is load-bearing: a line naming both a report document and the helper
classifies as `document` because that arm comes first.
#>
function Get-FmPendingReplyResolveVia {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return 'status' }
    foreach ($needle in @('data/', 'report.md', 'document', 'pointer')) {
        if ($needle -eq 'data/') {
            # `*data/*report*` - both, in order.
            $d = $Line.IndexOf('data/', $script:FmPrOrdinal)
            if ($d -ge 0 -and $Line.IndexOf('report', $d, $script:FmPrOrdinal) -ge 0) { return 'document' }
            continue
        }
        if ($Line.IndexOf($needle, $script:FmPrOrdinal) -ge 0) { return 'document' }
    }
    foreach ($needle in @('via-helper', 'fm-secondmate-report')) {
        if ($Line.IndexOf($needle, $script:FmPrOrdinal) -ge 0) { return 'helper' }
    }
    return 'status'
}

<#
.SYNOPSIS
Idempotently resolve an expectation from a correlated parent report.
.DESCRIPTION
Twin of fm_pending_reply_try_resolve. Returns $true when the record is resolved
AFTER the call - already or newly - which is what makes every caller's
"resolve wins" branch idempotent.

The scan-signature shortcut is skipped for an explicit status override and for
an unconfirmed delivery, exactly as in bash: those are the two cases where the
previous signature cannot be trusted to mean "nothing changed".
#>
function Resolve-FmPendingReply {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$StatusOverride
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if ([string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'resolved', $script:FmPrOrdinal)) {
        return $true
    }
    $delivered = Get-FmPendingReplyValue $rec 'delivered_epoch'
    $marker = $null
    $unconfirmed = $false
    if ([string]::IsNullOrEmpty($delivered)) {
        $marker = Get-FmPendingReplyConfirmationPath $State $CorrId
        $nativeMarker = ConvertTo-FmNativePath $marker
        if (-not [System.IO.File]::Exists($nativeMarker)) { return $false }
        $entry = (Get-FmFileText $nativeMarker).TrimEnd("`n")
        $eq = $entry.IndexOf('=')
        $deliveryState = if ($eq -ge 0) { $entry.Substring(0, $eq) } else { $entry }
        if ($deliveryState -cnotin @('attempted', 'confirmed')) { return $false }
        $unconfirmed = $true
    }

    $statusFile = if (-not [string]::IsNullOrEmpty($StatusOverride)) {
        $StatusOverride
    } else {
        Get-FmPendingReplyValue $rec 'parent_status'
    }

    $signature = $null
    $useSignature = ([string]::IsNullOrEmpty($StatusOverride) -and -not $unconfirmed)
    if ($useSignature) {
        $signature = Get-FmPendingReplyFileSignature $statusFile
        $previous = Get-FmPendingReplyValue $rec 'parent_status_scan_signature'
        if ([string]::Equals($signature, $previous, $script:FmPrOrdinal)) { return $false }
    }

    $line = Find-FmPendingReplyResolveLine $statusFile $CorrId
    if ([string]::IsNullOrEmpty($line)) {
        if ($useSignature) {
            if (-not (Set-FmPendingReplyValue $rec 'parent_status_scan_signature' $signature)) { return $false }
        }
        return $false
    }

    $via = Get-FmPendingReplyResolveVia $line
    $now = Get-FmPendingReplyNow
    if (-not (Set-FmPendingReplyValue $rec 'phase' 'resolved')) { return $false }
    if ([string]::IsNullOrEmpty($delivered)) {
        if (-not (Set-FmPendingReplyDelivered $State $CorrId $now)) { return $false }
        Remove-FmPendingReplyFile $marker
    }
    if (-not (Set-FmPendingReplyValue $rec 'resolved_epoch' $now)) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'resolved_via' $via)) { return $false }
    return $true
}

# --- turn observation ---------------------------------------------------------

<#
.SYNOPSIS
Record busy/idle evidence for the active turn. Returns 0/1/2 as the twin does.
.DESCRIPTION
Twin of fm_pending_reply_observe_busy: 0 for handled (including deliberately
ignored phases), 1 for a write failure, 2 for an unrecognised busy_state. Never
reads the secondmate's conversation.

The `idle` arm accepts a pure idle after delivery, not only a busy->idle
transition, because a fast turn can complete between two observations - the bash
comment calls this out and the `[ "$seen" = 1 ] || [ "$seen" = 0 ]` shape is
reproduced rather than simplified to "always", so a record whose seen field is
some other value still does nothing.
#>
function Write-FmPendingReplyBusyObservation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin records observations unconditionally on the watcher hot path; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$BusyState
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return 1 }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ($phase -cnotin @('awaiting_report', 'recovery_sent')) { return 0 }
    if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) { return 0 }

    $fieldSeen = if ([string]::Equals($phase, 'awaiting_report', $script:FmPrOrdinal)) {
        'turn_seen_busy'
    } else { 'recovery_turn_seen_busy' }
    $fieldCompleted = if ([string]::Equals($phase, 'awaiting_report', $script:FmPrOrdinal)) {
        'request_turn_completed_epoch'
    } else { 'recovery_turn_completed_epoch' }

    $seen = Get-FmPendingReplyValue $rec $fieldSeen
    $completed = Get-FmPendingReplyValue $rec $fieldCompleted

    switch -CaseSensitive ($BusyState) {
        'busy' {
            if (-not [string]::Equals($seen, '1', $script:FmPrOrdinal)) {
                if (-not (Set-FmPendingReplyValue $rec $fieldSeen '1')) { return 1 }
            }
            return 0
        }
        'idle' {
            if ([string]::IsNullOrEmpty($completed)) {
                if ([string]::Equals($seen, '1', $script:FmPrOrdinal) -or
                    [string]::Equals($seen, '0', $script:FmPrOrdinal)) {
                    if (-not (Set-FmPendingReplyValue $rec $fieldCompleted (Get-FmPendingReplyNow))) { return 1 }
                }
            }
            return 0
        }
        'unknown' { return 0 }
        default { return 2 }
    }
}

<#
.SYNOPSIS
True when a weak rendered idle may be accepted as a real idle.
.DESCRIPTION
Twin of fm_pending_reply_fallback_idle_eligible: a turn already SEEN busy is
eligible immediately; otherwise the grace window since the turn started must
have elapsed.
#>
function Test-FmPendingReplyFallbackIdleEligible {
    [CmdletBinding()][OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath)

    $phase = Get-FmPendingReplyValue $RecordPath 'phase'
    $start = ''
    $seen = ''
    if ([string]::Equals($phase, 'awaiting_report', $script:FmPrOrdinal)) {
        $start = Get-FmPendingReplyValue $RecordPath 'delivered_epoch'
        $seen = Get-FmPendingReplyValue $RecordPath 'turn_seen_busy'
    } elseif ([string]::Equals($phase, 'recovery_sent', $script:FmPrOrdinal)) {
        $start = Get-FmPendingReplyValue $RecordPath 'recovery_sent_epoch'
        $seen = Get-FmPendingReplyValue $RecordPath 'recovery_turn_seen_busy'
    } else {
        return $false
    }
    if ([string]::Equals($seen, '1', $script:FmPrOrdinal)) { return $true }
    if ($start -notmatch '^[0-9]+$') { return $false }
    $grace = Get-FmPendingReplyValue $RecordPath 'grace_secs'
    if ($grace -notmatch '^[0-9]+$') { $grace = Get-FmPendingReplyGraceSec }
    return ((([long](Get-FmPendingReplyNow)) - [long]$start) -ge [long]$grace)
}

<#
.SYNOPSIS
One busy/idle observation of a SECONDMATE endpoint, without reading its chat.
.DESCRIPTION
Twin of fm_pending_reply_backend_observation, and deliberately NOT the semantic
busy-state contract (bin/fm-busy-lib). That contract covers ordinary task
workers whose turn lifecycle firstmate wires at spawn; a secondmate has no such
wiring, because an idle secondmate pane is healthy and it runs no supervised
turn sequence of its own. This exists only to notice a busy-then-idle transition
around one delivered request.

Stays harness-scoped, so one harness's output cannot make another read busy, and
a weak rendered idle degrades to `fallback-idle`, which the caller accepts as
idle only after its grace window.
#>
function Get-FmPendingReplyBackendObservation {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Harness
    )
    $native = 'unknown'
    try { $native = [string](Get-FmBackendBusyState $Backend $Target) } catch { $native = 'unknown' }
    if ($native -cin @('busy', 'idle')) { return $native }

    $tail = $null
    try { $tail = [string](Get-FmBackendCapture $Backend $Target 40 $ExpectedLabel) } catch { return 'unknown' }
    if ($null -eq $tail) { return 'unknown' }

    # `grep -v '^[[:space:]]*$' | tail -6` before matching.
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($tail -split "`n")) {
        if ([regex]::IsMatch($line, '^\s*$')) { continue }
        $kept.Add($line)
    }
    $last = if ($kept.Count -gt 6) { $kept.GetRange($kept.Count - 6, 6) } else { $kept }
    if (Test-FmTmuxBusyLine ($last -join "`n") $Harness) { return 'busy' }
    return 'fallback-idle'
}

<#
.SYNOPSIS
Turn a raw observation into the busy state the record machinery accepts.
#>
function Get-FmPendingReplyBusyState {
    [CmdletBinding()][OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Observation
    )
    if ($Observation -cin @('busy', 'idle', 'unknown')) { return $Observation }
    if ([string]::Equals($Observation, 'fallback-idle', $script:FmPrOrdinal)) {
        if (Test-FmPendingReplyFallbackIdleEligible $RecordPath) { return 'idle' }
        return 'unknown'
    }
    return 'unknown'
}

<#
.SYNOPSIS
Explicit turn-completion proof. Returns 0/1/2 as the twin does.
#>
function Set-FmPendingReplyTurnCompleted {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin records completion unconditionally; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Which = 'request'
    )
    if ([string]::IsNullOrEmpty($Which)) { $Which = 'request' }
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return 1 }
    $field = switch -CaseSensitive ($Which) {
        'request'  { 'request_turn_completed_epoch' }
        'recovery' { 'recovery_turn_completed_epoch' }
        default    { $null }
    }
    if ($null -eq $field) { return 2 }
    if (-not (Set-FmPendingReplyValue $rec $field (Get-FmPendingReplyNow))) { return 1 }
    return 0
}

# --- recovery -----------------------------------------------------------------

<#
.SYNOPSIS
The one automatic recovery message for a pending record.
#>
function Get-FmPendingReplyRecoveryMessage {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath)

    $corr = Get-FmPendingReplyValue $RecordPath 'corr_id'
    $summary = Get-FmPendingReplyValue $RecordPath 'request_summary'
    $token = Get-FmPendingReplyCorrToken $corr
    $msg = "REPOST REQUIRED: previous marked request had no correlated parent report. " +
           "Reply on the parent status channel including ${token}. Original request: ${summary}"
    return (Add-FmPendingReplyCorr $msg $corr)
}

<#
.SYNOPSIS
A stable identity for the process owning an in-flight recovery send.
.DESCRIPTION
Twin of fm_pending_reply_pid_identity. See header note 2 for why this duplicates
fm-wake-lib's Get-FmPidIdentity rather than importing it, and for the two
divergences that are correct.

The /proc branch is preferred where readable: stat field 22 (starttime, in clock
ticks since boot) is immune to the wall-clock steps that re-render the ps
fallback and would drop a live sender's record into unknown-delivery escalation,
and the full NUL-separated cmdline keeps PID reuse a mismatch even on a tick
collision.
#>
function Get-FmPendingReplyPidIdentity {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProcessId)

    if ([string]::IsNullOrEmpty($ProcessId)) { return $null }
    if ($ProcessId -notmatch '^[0-9]+$') { return $null }

    $override = Get-FmEnv -Name 'FM_PROC_ROOT_OVERRIDE'
    $procRoot = if ($override) { $override } else { '/proc' }
    # A bare /proc can never resolve for a native Windows process; an explicit
    # override is always honored (the suites build a real one).
    $tryProc = $true
    if ((Test-FmWindows) -and -not $override) { $tryProc = $false }

    if ($tryProc) {
        $statPath = ConvertTo-FmNativePath "$procRoot/$ProcessId/stat"
        $cmdPath = ConvertTo-FmNativePath "$procRoot/$ProcessId/cmdline"
        if ([System.IO.File]::Exists($statPath) -and [System.IO.File]::Exists($cmdPath)) {
            try {
                $statLine = ([System.IO.File]::ReadAllText($statPath)).TrimEnd("`n")
            } catch { return $null }
            # `${stat_line##*)}` - after the FINAL comm delimiter, so a comm
            # containing ')' and spaces cannot shift the field indices.
            $close = $statLine.LastIndexOf(')')
            $rest = if ($close -ge 0) { $statLine.Substring($close + 1) } else { $statLine }
            $fields = @($rest -split '\s+' | Where-Object { $_ -ne '' })
            if ($fields.Count -lt 20) { return $null }
            $startTime = $fields[19]
            if ($startTime -notmatch '^[0-9]+$') { return $null }
            try { $cmdBytes = [System.IO.File]::ReadAllBytes($cmdPath) } catch { return $null }
            if ($cmdBytes.Length -eq 0) { return $null }
            $sb = [System.Text.StringBuilder]::new($cmdBytes.Length * 2)
            foreach ($b in $cmdBytes) { [void]$sb.Append($b.ToString('x2')) }
            return "proc-starttime=$startTime cmdline-hex=$($sb.ToString())"
        }
    }

    if (Test-FmWindows) {
        # Neither source exists for a native process, so a deliberately
        # DIFFERENT key is emitted: a cross-world comparison must read as
        # MISMATCH rather than silently matching (header note 2).
        $info = Get-FmNativeProcessInfo -ProcessId $ProcessId
        if (-not $info) { return $null }
        try {
            $proc = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
            $ticks = $proc.StartTime.Ticks
        } catch { return $null }
        $cmdline = Get-FmProcCommandLine -ProcessId $ProcessId
        if ($null -eq $cmdline) { $cmdline = '' }
        $bytes = $script:FmPrUtf8.GetBytes($cmdline)
        $sb = [System.Text.StringBuilder]::new($bytes.Length * 2)
        foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
        return "win-starttime=$ticks cmdline-hex=$($sb.ToString())"
    }

    # `COLUMNS=10000 LC_ALL=C ps -p <pid> -o lstart= -o command=`, with LC_ALL
    # pinned exactly as the bash twin pins it: the identity is written under one
    # locale and re-read under the machine's ambient locale, and an unpinned
    # lstart would mismatch on a non-C locale and drop a live sender.
    $r = Invoke-FmTool -FilePath 'ps' -Arguments @('-p', $ProcessId, '-o', 'lstart=', '-o', 'command=')
    if (-not $r.Ok) { return $null }
    $identity = $r.StdOut.TrimEnd("`n")
    if ([string]::IsNullOrEmpty($identity)) { return $null }
    return $identity
}

<#
.SYNOPSIS
True when the process that started a recovery send is still that same process.
#>
function Test-FmPendingReplySenderAlive {
    [CmdletBinding()][OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$RecordPath)

    $expected = Get-FmPendingReplyValue $RecordPath 'recovery_sender_identity'
    if ([string]::IsNullOrEmpty($expected)) { return $false }
    $actual = Get-FmPendingReplyPidIdentity (Get-FmPendingReplyValue $RecordPath 'recovery_sender_pid')
    if ([string]::IsNullOrEmpty($actual)) { return $false }
    return [string]::Equals($actual, $expected, $script:FmPrOrdinal)
}

<#
.SYNOPSIS
Settle a recovery attempt as confirmed or failed. Returns $true on success.
#>
function Complete-FmPendingReplyRecovery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin settles the attempt unconditionally; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Outcome
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if (-not [string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'recovery_sending', $script:FmPrOrdinal)) {
        return $false
    }
    if (-not (Set-FmPendingReplyValue $rec 'recovery_delivery_outcome' $Outcome)) { return $false }
    if ([string]::Equals($Outcome, 'confirmed', $script:FmPrOrdinal)) {
        if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'recovery_sent_epoch'))) {
            if (-not (Set-FmPendingReplyValue $rec 'recovery_sent_epoch' (Get-FmPendingReplyNow))) { return $false }
        }
        if (-not (Set-FmPendingReplyValue $rec 'recovery_turn_seen_busy' '0')) { return $false }
        if (-not (Set-FmPendingReplyValue $rec 'recovery_turn_completed_epoch' '')) { return $false }
        return (Set-FmPendingReplyValue $rec 'phase' 'recovery_sent')
    }
    if (-not [string]::Equals($Outcome, 'failed', $script:FmPrOrdinal)) { return $false }
    return (Set-FmPendingReplyValue $rec 'phase' 'recovery_failed')
}

<#
.SYNOPSIS
Reconcile a recovery attempt whose outcome was lost. Returns $true when settled.
.DESCRIPTION
Twin of fm_pending_reply_reconcile_recovery. When no outcome was recorded, a
STILL-LIVE sender means "leave it alone" (returns $false); a dead sender means
the attempt's fate is genuinely unknown, which is recorded rather than guessed.
#>
function Sync-FmPendingReplyRecovery {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ($phase -cnotin @('awaiting_report', 'recovery_sending')) { return $false }
    $attempted = Get-FmPendingReplyValue $rec 'recovery_attempted_epoch'
    if ([string]::IsNullOrEmpty($attempted)) { return $false }
    if ($attempted -notmatch '^[0-9]+$') { return $false }
    $outcome = Get-FmPendingReplyValue $rec 'recovery_delivery_outcome'
    switch -CaseSensitive ($outcome) {
        'confirmed' { return (Complete-FmPendingReplyRecovery $State $CorrId 'confirmed') }
        'failed'    { return (Complete-FmPendingReplyRecovery $State $CorrId 'failed') }
        'unknown'   { return (Set-FmPendingReplyValue $rec 'phase' 'recovery_unknown') }
    }
    if (Test-FmPendingReplySenderAlive $rec) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'recovery_delivery_outcome' 'unknown')) { return $false }
    return (Set-FmPendingReplyValue $rec 'phase' 'recovery_unknown')
}

<#
.SYNOPSIS
Deliver the ONE automatic recovery message. Returns $true only when it landed.
.DESCRIPTION
Twin of fm_pending_reply_send_recovery. Every precondition is preserved, in
order, because together they are what stops the "never loop, never repeatedly
inject" guarantee from degrading: phase must be awaiting_report, no attempt may
already exist, the request turn must have completed, delivery must be recorded,
and the grace window must have elapsed.

-SendAction is the seam for FM_PENDING_REPLY_SEND_HOOK and for the fm-send
child. The bash twin `eval`s a hook template or executes bin/fm-send.sh; a
scriptblock is the PowerShell equivalent, and Invoke-FmScript keeps the fm-send
edge transition-safe when no hook is supplied.
#>
function Send-FmPendingReplyRecovery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin sends the single recovery message unconditionally once its preconditions hold; a -WhatIf/-Confirm surface would diverge from the twin.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [scriptblock]$SendAction
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if (-not [string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'awaiting_report', $script:FmPrOrdinal)) {
        return $false
    }
    if (-not [string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'recovery_attempted_epoch'))) {
        [void](Sync-FmPendingReplyRecovery $State $CorrId)
        return $false
    }
    if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'request_turn_completed_epoch'))) { return $false }
    $delivered = Get-FmPendingReplyValue $rec 'delivered_epoch'
    if ([string]::IsNullOrEmpty($delivered)) { return $false }
    $grace = Get-FmPendingReplyValue $rec 'grace_secs'
    if ($grace -notmatch '^[0-9]+$') { $grace = Get-FmPendingReplyGraceSec }
    $now = Get-FmPendingReplyNow
    if ($delivered -notmatch '^[0-9]+$') { return $false }
    if (([long]$now - [long]$delivered) -lt [long]$grace) { return $false }

    $taskId = Get-FmPendingReplyValue $rec 'task_id'
    $parentHome = Get-FmPendingReplyValue $rec 'parent_home'
    $msg = Get-FmPendingReplyRecoveryMessage $rec

    $senderPid = [string]$PID
    $senderIdentity = Get-FmPendingReplyPidIdentity $senderPid
    if ([string]::IsNullOrEmpty($senderIdentity)) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'recovery_sender_pid' $senderPid)) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'recovery_sender_identity' $senderIdentity)) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'recovery_attempted_epoch' $now)) { return $false }
    if (-not (Set-FmPendingReplyValue $rec 'phase' 'recovery_sending')) { return $false }

    $sent = $false
    if ($SendAction) {
        try { $sent = [bool](& $SendAction $taskId $msg) } catch { $sent = $false }
    } elseif ([string]::IsNullOrEmpty($parentHome) -or
              -not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $parentHome))) {
        $sent = $false
    } else {
        $prevHome = [Environment]::GetEnvironmentVariable('FM_HOME')
        $prevCorr = [Environment]::GetEnvironmentVariable('FM_PENDING_REPLY_EXISTING_CORR')
        try {
            [Environment]::SetEnvironmentVariable('FM_HOME', $parentHome)
            [Environment]::SetEnvironmentVariable('FM_PENDING_REPLY_EXISTING_CORR', $CorrId)
            $r = Invoke-FmScript -Name 'fm-send' -Arguments @($taskId, $msg)
            $sent = $r.Ok
        } catch {
            $sent = $false
        } finally {
            [Environment]::SetEnvironmentVariable('FM_HOME', $prevHome)
            [Environment]::SetEnvironmentVariable('FM_PENDING_REPLY_EXISTING_CORR', $prevCorr)
        }
    }

    if ($sent) { return (Complete-FmPendingReplyRecovery $State $CorrId 'confirmed') }
    [void](Complete-FmPendingReplyRecovery $State $CorrId 'failed')
    return $false
}

# --- escalation ---------------------------------------------------------------

<#
.SYNOPSIS
Escalate ONCE after a missed recovery report or a failed delivery outcome.
.DESCRIPTION
Twin of fm_pending_reply_maybe_escalate. Retains the durable unresolved record
and never loops. A late report arriving between completion and this call still
WINS - the resolve attempt comes first.

The escalation line uses `pending-reply-id=` and not `corr=` precisely so this
parent-written line cannot be mistaken for a secondmate acknowledgement by
Test-FmPendingReplyResolvingLine, and it is appended only when an identical line
is not already present.
#>
function Invoke-FmPendingReplyEscalation {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ([string]::Equals($phase, 'delivery_unknown', $script:FmPrOrdinal)) {
        [void](Sync-FmPendingReplyDelivery $State $CorrId)
        $phase = Get-FmPendingReplyValue $rec 'phase'
        if (-not [string]::Equals($phase, 'delivery_unknown', $script:FmPrOrdinal)) { return $true }
    }
    if ([string]::Equals($phase, 'recovery_sent', $script:FmPrOrdinal)) {
        if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'recovery_turn_completed_epoch'))) {
            return $false
        }
    } elseif ($phase -cnotin @('delivery_unknown', 'recovery_failed', 'recovery_unknown')) {
        return $false
    }

    if (Resolve-FmPendingReply $State $CorrId) { return $true }

    $taskId = Get-FmPendingReplyValue $rec 'task_id'
    $summary = Get-FmPendingReplyValue $rec 'request_summary'
    $parentStatus = Get-FmPendingReplyValue $rec 'parent_status'
    $outcome = Get-FmPendingReplyValue $rec 'recovery_delivery_outcome'
    $payload = switch -CaseSensitive ($phase) {
        'delivery_unknown' { "pending-reply-delivery-unknown: task=${taskId} pending-reply-id=${CorrId} request=${summary}" }
        'recovery_failed'  { "pending-reply-recovery-delivery-${outcome}: task=${taskId} pending-reply-id=${CorrId} request=${summary}" }
        'recovery_unknown' { "pending-reply-recovery-delivery-${outcome}: task=${taskId} pending-reply-id=${CorrId} request=${summary}" }
        default            { "pending-reply-missed: task=${taskId} pending-reply-id=${CorrId} request=${summary}" }
    }
    if ([string]::IsNullOrEmpty($parentStatus)) { return $false }
    $nativeStatus = ConvertTo-FmNativePath $parentStatus
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($nativeStatus))
    } catch { return $false }

    $wanted = "blocked: $payload"
    $present = $false
    foreach ($line in (Get-FmFileLines $nativeStatus)) {
        if ([string]::Equals($line, $wanted, $script:FmPrOrdinal)) { $present = $true; break }
    }
    if (-not $present) {
        try { Add-FmFileLine -Path $nativeStatus -Line $wanted } catch { return $false }
    }
    $now = Get-FmPendingReplyNow
    if (-not (Set-FmPendingReplyValue $rec 'escalated_epoch' $now)) { return $false }
    return (Set-FmPendingReplyValue $rec 'phase' 'escalated')
}

<#
.SYNOPSIS
Count correlated reports written under the SECONDMATE home (the wrong one).
.DESCRIPTION
Twin of fm_pending_reply_detect_wrong_home. Counting a sighting is explicitly
NOT acknowledgement - the record stays unresolved - and each sighting is
identified by a cksum over its file, line number and text so the same line is
never counted twice across ticks.
#>
function Find-FmPendingReplyWrongHome {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$SecondmateHome
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    if ([string]::IsNullOrEmpty($SecondmateHome)) { return $true }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $SecondmateHome))) { return $true }
    if ([string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'resolved', $script:FmPrOrdinal)) { return $true }
    if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) { return $true }

    $snapshot = Get-FmPendingReplyStatusSetSignature "$SecondmateHome/state"
    $previous = Get-FmPendingReplyValue $rec 'wrong_home_scan_signature'
    if ([string]::Equals($snapshot, $previous, $script:FmPrOrdinal)) { return $true }

    $hits = Get-FmPendingReplyValue $rec 'wrong_home_hits'
    if ($hits -notmatch '^[0-9]+$') { $hits = '0' }
    [long]$hitCount = [long]$hits
    $sightings = Get-FmPendingReplyValue $rec 'wrong_home_sightings'
    $changed = $false

    foreach ($statusFile in (Get-FmPendingReplyStatusFile -Directory "$SecondmateHome/state")) {
        $lineNo = 0
        foreach ($line in (Get-FmFileLines (ConvertTo-FmNativePath $statusFile))) {
            $lineNo++
            if (-not (Test-FmPendingReplyResolvingLine $line $CorrId)) { continue }
            $sightingId = Get-FmPendingReplyCksum -Text ("{0}:{1}:{2}:{3}" -f $statusFile.Length, $statusFile, $lineNo, $line)
            if ([string]::IsNullOrEmpty($sightingId)) { continue }
            if (",$sightings,".IndexOf(",$sightingId,", $script:FmPrOrdinal) -ge 0) { continue }
            $sightings = if ([string]::IsNullOrEmpty($sightings)) { $sightingId } else { "$sightings,$sightingId" }
            $hitCount++
            $changed = $true
        }
    }
    if ($changed) {
        if (-not (Set-FmPendingReplyValue $rec 'wrong_home_sightings' $sightings)) { return $false }
        if (-not (Set-FmPendingReplyValue $rec 'wrong_home_hits' ([string]$hitCount))) { return $false }
    }
    return (Set-FmPendingReplyValue $rec 'wrong_home_scan_signature' $snapshot)
}

# --- POSIX cksum --------------------------------------------------------------
#
# See header note 1. The table is built once per process; the algorithm is
# CRC-32 poly 0x04C11DB7 MSB-first with init 0, then the LENGTH folded in
# base-256 low-byte-first, then complemented. Rendered `<crc>-<bytes>` to match
# the bash twin's `awk '{printf "%s-%s", $1, $2}'`.

$script:FmPrCksumTable = $null

function Get-FmPendingReplyCksumTable {
    if ($null -ne $script:FmPrCksumTable) { return $script:FmPrCksumTable }
    $t = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        [uint32]$c = [uint32]$i -shl 24
        for ($k = 0; $k -lt 8; $k++) {
            if ($c -band 0x80000000) { $c = (($c -shl 1) -bxor 0x04C11DB7) -band 0xFFFFFFFF }
            else { $c = ($c -shl 1) -band 0xFFFFFFFF }
        }
        $t[$i] = $c
    }
    $script:FmPrCksumTable = $t
    return $t
}

<#
.SYNOPSIS
POSIX cksum of a string, rendered `<crc>-<bytes>`.
#>
function Get-FmPendingReplyCksum {
    [CmdletBinding()][OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $bytes = $script:FmPrUtf8.GetBytes($Text)
    $tab = Get-FmPendingReplyCksumTable
    [uint32]$crc = 0
    foreach ($b in $bytes) {
        $crc = (($crc -shl 8) -band 0xFFFFFFFF) -bxor $tab[(($crc -shr 24) -bxor $b) -band 0xFF]
    }
    [long]$len = $bytes.Length
    while ($len -gt 0) {
        $crc = (($crc -shl 8) -band 0xFFFFFFFF) -bxor $tab[(($crc -shr 24) -bxor ($len -band 0xFF)) -band 0xFF]
        $len = [long][Math]::Floor($len / 256)
    }
    $final = ($crc -bxor 0xFFFFFFFF) -band 0xFFFFFFFF
    return ('{0}-{1}' -f $final, $bytes.Length)
}

# --- native file identity -----------------------------------------------------
#
# st_dev and st_ino, which .NET exposes on neither platform. One
# GetFileInformationByHandle answers both on Windows and its values are the SAME
# NUMBERS MSYS stat prints (header note 1). FILE_FLAG_BACKUP_SEMANTICS is what
# makes the call work for a directory; dwDesiredAccess is 0 and the share mode is
# READ|WRITE|DELETE, so a file another process holds open still answers.

$script:FmPrNativeReady = $false
$script:FmPrNativeUsable = $false

function Initialize-FmPendingReplyNativeApi {
    [CmdletBinding()][OutputType([bool])] param()
    if ($script:FmPrNativeReady) { return $script:FmPrNativeUsable }
    $script:FmPrNativeReady = $true
    if (-not (Test-FmWindows)) { return $false }
    if (([System.Management.Automation.PSTypeName]'Firstmate.PendingReply.NativeFile').Type) {
        $script:FmPrNativeUsable = $true
        return $true
    }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Firstmate.PendingReply {
    // Pack = 4 is load-bearing: the native BY_HANDLE_FILE_INFORMATION packs its
    // FILETIME members on 4-byte boundaries, and the default managed 8-byte
    // alignment shifts every field after the first one.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct FileIdentity {
        public uint Attributes;
        public uint CreationLow;   public uint CreationHigh;
        public uint AccessLow;     public uint AccessHigh;
        public uint WriteLow;      public uint WriteHigh;
        public uint VolumeSerialNumber;
        public uint SizeHigh;      public uint SizeLow;
        public uint NumberOfLinks;
        public uint IndexHigh;     public uint IndexLow;
    }

    public static class NativeFile {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(
            string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileIdentity info);
    }
}
'@
        $script:FmPrNativeUsable = $true
    } catch {
        $script:FmPrNativeUsable = $false
    }
    return $script:FmPrNativeUsable
}

<#
.SYNOPSIS
The device and inode of a path, or $null.
#>
function Get-FmPendingReplyFileIdentity {
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Initialize-FmPendingReplyNativeApi)) {
        # Off Windows `stat` is the twin's own source and is authoritative.
        $r = Invoke-FmTool -FilePath 'stat' -Arguments @('-c', '%d:%i', $Path)
        if (-not $r.Ok) { return $null }
        $parts = @($r.StdOut.Trim().Split(':'))
        if ($parts.Count -ne 2) { return $null }
        return @{ Device = $parts[0]; Inode = $parts[1] }
    }
    $handle = [Firstmate.PendingReply.NativeFile]::CreateFileW(
        $Path, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($handle.IsInvalid) { return $null }
    try {
        $info = New-Object Firstmate.PendingReply.FileIdentity
        if (-not [Firstmate.PendingReply.NativeFile]::GetFileInformationByHandle($handle, [ref]$info)) {
            return $null
        }
        $inode = ([long]$info.IndexHigh -shl 32) -bor [long]$info.IndexLow
        return @{ Device = [string]$info.VolumeSerialNumber; Inode = [string]$inode }
    } finally {
        $handle.Close()
    }
}

# --- the tick -----------------------------------------------------------------

<#
.SYNOPSIS
One reconciliation tick for a single record: resolve, observe, recover, escalate.
.DESCRIPTION
Twin of fm_pending_reply_tick_one, in the twin's exact order, because the order
IS the safety property: a correlated parent report always wins and is idempotent,
recovery is attempted at most once, and escalation happens only after the turn
that should have carried the report has completed.
#>
function Update-FmPendingReplyRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin ticks unconditionally on the watcher poll; a -WhatIf/-Confirm surface would diverge from the twin and could stall supervision.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$CorrId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$BusyState,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$SecondmateHome,
        [scriptblock]$SendAction
    )
    $rec = Get-FmPendingReplyPath $State $CorrId
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $rec))) { return $false }
    [void](Sync-FmPendingReplyDelivery $State $CorrId)
    $phase = Get-FmPendingReplyValue $rec 'phase'

    if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) {
        if ([string]::Equals($phase, 'delivery_unknown', $script:FmPrOrdinal)) {
            [void](Invoke-FmPendingReplyEscalation $State $CorrId)
        } elseif ([string]::Equals($phase, 'escalated', $script:FmPrOrdinal)) {
            [void](Resolve-FmPendingReply $State $CorrId)
        }
        return $true
    }

    if (Resolve-FmPendingReply $State $CorrId) { return $true }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ($phase -cin @('awaiting_report', 'recovery_sending')) {
        if (-not [string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'recovery_attempted_epoch'))) {
            [void](Sync-FmPendingReplyRecovery $State $CorrId)
            $phase = Get-FmPendingReplyValue $rec 'phase'
        }
    }

    switch -CaseSensitive ($phase) {
        'resolved' { return $true }
        'escalated' {
            # Unresolved durable record retained; never auto-deleted.
            if (-not [string]::IsNullOrEmpty($SecondmateHome)) {
                [void](Find-FmPendingReplyWrongHome $State $CorrId $SecondmateHome)
            }
            return $true
        }
        'recovery_sending' { return $true }
        'recovery_failed' {
            [void](Invoke-FmPendingReplyEscalation $State $CorrId)
            return $true
        }
        'recovery_unknown' {
            [void](Invoke-FmPendingReplyEscalation $State $CorrId)
            return $true
        }
    }

    if (-not [string]::IsNullOrEmpty($SecondmateHome)) {
        [void](Find-FmPendingReplyWrongHome $State $CorrId $SecondmateHome)
    }
    [void](Write-FmPendingReplyBusyObservation $State $CorrId $BusyState)
    # Re-check resolve after observation in case a concurrent status write landed.
    if (Resolve-FmPendingReply $State $CorrId) { return $true }

    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ([string]::Equals($phase, 'awaiting_report', $script:FmPrOrdinal)) {
        [void](Send-FmPendingReplyRecovery $State $CorrId -SendAction $SendAction)
    }
    $phase = Get-FmPendingReplyValue $rec 'phase'
    if ($phase -cin @('recovery_sent', 'recovery_failed', 'recovery_unknown')) {
        [void](Invoke-FmPendingReplyEscalation $State $CorrId)
    }
    return $true
}

<#
.SYNOPSIS
Scan every pending record for this parent state. Safe to call every poll.
.DESCRIPTION
Twin of fm_pending_reply_tick. Never scrapes secondmate conversation; uses only
parent status, backend busy state, and optional wrong-home path checks. One
backend observation per TASK is reused across that task's records, exactly as
the bash twin memoizes with its parallel arrays.
#>
function Update-FmPendingReply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin ticks unconditionally on the watcher poll; a -WhatIf/-Confirm surface would diverge from the twin and could stall supervision.')]
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [scriptblock]$SendAction
    )
    $dir = Get-FmPendingReplyDir $State
    $nativeDir = ConvertTo-FmNativePath $dir
    if (-not [System.IO.Directory]::Exists($nativeDir)) { return $true }

    $observations = @{}
    foreach ($entry in ([System.IO.Directory]::EnumerateFileSystemEntries($nativeDir) | Sort-Object)) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($name.StartsWith('.', $script:FmPrOrdinal)) { continue }
        if (-not [System.IO.File]::Exists($entry)) { continue }
        $rec = "$dir/$name"

        $corr = Get-FmPendingReplyValue $rec 'corr_id'
        if ([string]::IsNullOrEmpty($corr)) { $corr = $name }
        $taskId = Get-FmPendingReplyValue $rec 'task_id'
        $phase = Get-FmPendingReplyValue $rec 'phase'
        if ([string]::Equals($phase, 'resolved', $script:FmPrOrdinal)) { continue }

        [void](Sync-FmPendingReplyDelivery $State $corr)
        $phase = Get-FmPendingReplyValue $rec 'phase'
        if ([string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'delivered_epoch'))) {
            if ($phase -cin @('delivery_unknown', 'escalated')) {
                [void](Update-FmPendingReplyRecord $State $corr 'unknown' '' -SendAction $SendAction)
            }
            continue
        }

        if ($phase -cin @('awaiting_report', 'recovery_sending')) {
            if (-not [string]::IsNullOrEmpty((Get-FmPendingReplyValue $rec 'recovery_attempted_epoch'))) {
                [void](Sync-FmPendingReplyRecovery $State $corr)
                $phase = Get-FmPendingReplyValue $rec 'phase'
            }
        }

        $meta = "$State/$taskId.meta"
        $metaNative = ConvertTo-FmNativePath $meta
        $metaExists = [System.IO.File]::Exists($metaNative)

        if ([string]::Equals($phase, 'escalated', $script:FmPrOrdinal)) {
            if (Resolve-FmPendingReply $State $corr) { continue }
            if ($metaExists) {
                $smHome = Get-FmMetaValue -MetaPath $metaNative -Key 'home'
                if (-not [string]::IsNullOrEmpty($smHome)) {
                    [void](Find-FmPendingReplyWrongHome $State $corr $smHome)
                }
            }
            continue
        }
        if ($phase -cin @('recovery_failed', 'recovery_unknown')) {
            [void](Update-FmPendingReplyRecord $State $corr 'unknown' '' -SendAction $SendAction)
            continue
        }
        if ($phase -cnotin @('awaiting_report', 'recovery_sent')) { continue }

        $busy = 'unknown'
        $smHome = ''
        if ($metaExists) {
            $backend = Get-FmBackendOfMeta $metaNative
            $target = Get-FmBackendTargetOfMeta $metaNative
            $smHome = Get-FmMetaValue -MetaPath $metaNative -Key 'home'
            $harness = Get-FmMetaValue -MetaPath $metaNative -Key 'harness'
            if (-not [string]::IsNullOrEmpty($target)) {
                if (-not $observations.ContainsKey($taskId)) {
                    $observations[$taskId] = Get-FmPendingReplyBackendObservation `
                        $backend $target "fm-$taskId" $harness
                }
                $busy = Get-FmPendingReplyBusyState $rec $observations[$taskId]
            }
        }
        [void](Update-FmPendingReplyRecord $State $corr $busy $smHome -SendAction $SendAction)
    }
    return $true
}

<#
.SYNOPSIS
True when any open (non-resolved) pending reply exists for a task.
#>
function Test-FmPendingReplyTaskHasOpen {
    [CmdletBinding()][OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TaskId
    )
    $dir = Get-FmPendingReplyDir $State
    $nativeDir = ConvertTo-FmNativePath $dir
    if (-not [System.IO.Directory]::Exists($nativeDir)) { return $false }
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($nativeDir)) {
        if (-not [System.IO.File]::Exists($entry)) { continue }
        $rec = "$dir/$([System.IO.Path]::GetFileName($entry))"
        if (-not [string]::Equals((Get-FmPendingReplyValue $rec 'task_id'), [string]$TaskId, $script:FmPrOrdinal)) {
            continue
        }
        if ([string]::Equals((Get-FmPendingReplyValue $rec 'phase'), 'resolved', $script:FmPrOrdinal)) { continue }
        return $true
    }
    return $false
}

Export-ModuleMember -Function @(
    'Get-FmPendingReplySchema', 'Get-FmPendingReplyCorrRegex', 'Get-FmPendingReplyGraceDefault',
    'Get-FmPendingReplyNow', 'Get-FmPendingReplyGraceSec',
    'Get-FmPendingReplyDir', 'Get-FmPendingReplyPath',
    'New-FmPendingReplyId', 'Get-FmPendingReplyCorrToken', 'Get-FmPendingReplyCorr',
    'Test-FmPendingReplyTextHasCorr', 'Get-FmPendingReplySummary',
    'Get-FmPendingReplyValue', 'Set-FmPendingReplyValue', 'Test-FmPendingReplyCorrReusable',
    'Add-FmPendingReplyCorr', 'New-FmPendingReply',
    'Set-FmPendingReplyDelivered', 'Get-FmPendingReplyConfirmationPath',
    'Write-FmPendingReplyConfirmation', 'Initialize-FmPendingReplyDelivery',
    'Confirm-FmPendingReplyDelivery', 'Sync-FmPendingReplyDelivery',
    'Remove-FmPendingReplyUndelivered',
    'Test-FmPendingReplyResolvingLine', 'Find-FmPendingReplyResolveLine',
    'Get-FmPendingReplyFileSignature', 'Get-FmPendingReplyStatusSetSignature',
    'Get-FmPendingReplyStatusFile', 'Get-FmPendingReplyResolveVia', 'Resolve-FmPendingReply',
    'Write-FmPendingReplyBusyObservation', 'Test-FmPendingReplyFallbackIdleEligible',
    'Get-FmPendingReplyBackendObservation', 'Get-FmPendingReplyBusyState',
    'Set-FmPendingReplyTurnCompleted', 'Get-FmPendingReplyRecoveryMessage',
    'Get-FmPendingReplyPidIdentity', 'Test-FmPendingReplySenderAlive',
    'Complete-FmPendingReplyRecovery', 'Sync-FmPendingReplyRecovery',
    'Send-FmPendingReplyRecovery', 'Invoke-FmPendingReplyEscalation',
    'Find-FmPendingReplyWrongHome', 'Get-FmPendingReplyCksum', 'Set-FmPendingReplyFileAtomic',
    'Get-FmPendingReplyFileIdentity',
    'Update-FmPendingReplyRecord', 'Update-FmPendingReply', 'Test-FmPendingReplyTaskHasOpen'
)
