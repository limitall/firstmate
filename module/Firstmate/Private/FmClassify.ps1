#requires -Version 7.0
# FmClassify.ps1 - internals of the shared wake classifier, ported from
# bin/fm-classify-lib.sh.
#
# The status stream is an append-only EVENT log, never current-state truth. Two
# folds live here and they must never drift apart:
#   * the decision fold - needs-decision/blocked OPENS a keyed decision and only
#     resolved/captain-held carrying that exact key CLOSES it, so a later
#     unrelated done: or working: line can never clear a captain decision;
#   * the activity fold - working/paused opens a keyed phase that a later
#     terminal or separately tracked event for the same key supersedes.
# Both consume Add-FmClassifyDecisionFoldLine / Add-FmClassifyActivityFoldLine,
# the single place each per-line rule is written, exactly as the bash library
# routes its whole-file and incremental folds through _fm_decision_fold_line.

Set-StrictMode -Version Latest

$script:FmClassifyCaptainReDefault = 'done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'
$script:FmClassifyPausedVerbDefault = 'paused'
$script:FmClassifyResolveVerbDefault = 'resolved'
$script:FmClassifyCaptainHeldVerbDefault = 'captain-held'
$script:FmClassifyReservedKeyPrefixesDefault = 'pending-reply-'
$script:FmClassifyPauseResurfaceSecsDefault = 3600
# Bump only when the per-line fold semantics change, so a cursor persisted under
# an older interpretation is discarded and rebuilt from byte 0.
#
# 3, not the bash library's 2: Get-FmStatusDecisionKey also honours a key token
# written in the leading position of the note, which bash folds as `default`
# (see its header). A cursor written under the old reading holds an open set
# derived from it, and only a version bump rebuilds that set from byte 0.
$script:FmOpenDecisionsFoldVersion = 3

function Get-FmClassifyPausedVerb { if ($env:FM_CLASSIFY_PAUSED_VERB) { $env:FM_CLASSIFY_PAUSED_VERB } else { $script:FmClassifyPausedVerbDefault } }
function Get-FmClassifyResolveVerb { if ($env:FM_CLASSIFY_RESOLVE_VERB) { $env:FM_CLASSIFY_RESOLVE_VERB } else { $script:FmClassifyResolveVerbDefault } }
function Get-FmClassifyCaptainHeldVerb { if ($env:FM_CLASSIFY_CAPTAIN_HELD_VERB) { $env:FM_CLASSIFY_CAPTAIN_HELD_VERB } else { $script:FmClassifyCaptainHeldVerbDefault } }
function Get-FmClassifyCaptainRegex { if ($null -ne $env:FM_CAPTAIN_RE) { $env:FM_CAPTAIN_RE } else { $script:FmClassifyCaptainReDefault } }
function Test-FmClassifyCaptainRegexOverridden { return ($null -ne $env:FM_CAPTAIN_RE) }
function Get-FmClassifyPauseResurfaceSecs {
    if ($env:FM_PAUSE_RESURFACE_SECS -match '^[0-9]+$') { return [int]$env:FM_PAUSE_RESURFACE_SECS }
    return $script:FmClassifyPauseResurfaceSecsDefault
}
function Get-FmClassifyReservedKeyPrefix {
    $raw = if ($env:FM_CLASSIFY_RESERVED_KEY_PREFIXES) { $env:FM_CLASSIFY_RESERVED_KEY_PREFIXES } else { $script:FmClassifyReservedKeyPrefixesDefault }
    return @($raw -split '\s+' | Where-Object { $_ -ne '' })
}

# A reserved key (`pending-reply-<id>`) may only be opened or closed by a line
# whose note speaks that namespace's own vocabulary - it begins `<namespace>...:`.
# Without this rule any writer into the same stream could claim a reserved key
# and permanently block, or wrongly clear, the owner's decision.
function Test-FmClassifyReservedKeyTransitionAllowed {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Note
    )
    foreach ($prefix in Get-FmClassifyReservedKeyPrefix) {
        if ($Key.StartsWith($prefix)) {
            if ($Note.StartsWith($prefix) -and $Note.Substring($prefix.Length).Contains(':')) { return $true }
            return $false
        }
    }
    return $true
}

function New-FmClassifyOpenSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an empty in-memory list and changes nothing.')]
    param()
    # The unary comma keeps PowerShell from unrolling the empty list away.
    $set = [System.Collections.Generic.List[object]]::new()
    return , $set
}

function Remove-FmClassifyOpenKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates a list the caller owns and passed in; nothing outside this process changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$OpenSet,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key
    )
    for ($i = $OpenSet.Count - 1; $i -ge 0; $i--) {
        if ($OpenSet[$i].Key -eq $Key) { $OpenSet.RemoveAt($i) }
    }
}

function New-FmClassifyOpenRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record and changes nothing.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Verb,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Note
    )
    [pscustomobject]@{
        Key  = $Key
        Verb = $Verb
        Note = $Note
        Line = "$Key`t$Verb`t$Note"
    }
}

# Fold ONE status line into an open decision set. The single owner of the
# open/resolved rule; both the whole-file and the cursor-backed folds call it.
function Add-FmClassifyDecisionFoldLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$OpenSet,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    if (($Line -replace '\s', '') -eq '') { return }
    $verb = Get-FmStatusLineVerb -Line $Line
    $key = Get-FmStatusDecisionKey -Line $Line
    if ($null -eq $key) { return }
    $note = Get-FmStatusLineNote -Line $Line
    if (-not (Test-FmClassifyReservedKeyTransitionAllowed -Key $key -Note $note)) { return }
    $resolve = Get-FmClassifyResolveVerb
    $held = Get-FmClassifyCaptainHeldVerb
    if ($verb -ceq 'needs-decision' -or $verb -ceq 'blocked') {
        Remove-FmClassifyOpenKey -OpenSet $OpenSet -Key $key
        $OpenSet.Add((New-FmClassifyOpenRecord -Key $key -Verb $verb -Note $note))
    } elseif ($verb -ceq $resolve -or $verb -ceq $held) {
        Remove-FmClassifyOpenKey -OpenSet $OpenSet -Key $key
    }
}

# Fold ONE status line into the open ACTIVITY set: evidence about whether an
# earlier reported phase was explicitly superseded, never current crew state.
function Add-FmClassifyActivityFoldLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$OpenSet,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    if (($Line -replace '\s', '') -eq '') { return }
    $verb = Get-FmStatusLineVerb -Line $Line
    $key = Get-FmStatusDecisionKey -Line $Line
    if ($null -eq $key) { return }
    $pause = Get-FmClassifyPausedVerb
    $resolve = Get-FmClassifyResolveVerb
    $held = Get-FmClassifyCaptainHeldVerb
    if ($verb -ceq 'working' -or $verb -ceq $pause) {
        $note = Get-FmStatusLineNote -Line $Line
        Remove-FmClassifyOpenKey -OpenSet $OpenSet -Key $key
        $OpenSet.Add((New-FmClassifyOpenRecord -Key $key -Verb $verb -Note $note))
    } elseif ($verb -ceq 'done' -or $verb -ceq 'failed' -or $verb -ceq 'needs-decision' -or $verb -ceq 'blocked' -or $verb -ceq $resolve -or $verb -ceq $held) {
        Remove-FmClassifyOpenKey -OpenSet $OpenSet -Key $key
    }
}

# state/.<task>.open-decisions-cursor, the sibling record of the incremental fold.
function Get-FmClassifyCursorPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatusFile)
    $dir = Split-Path -Parent $StatusFile
    $base = Split-Path -Leaf $StatusFile
    if ($base.EndsWith('.status')) { $base = $base.Substring(0, $base.Length - '.status'.Length) }
    return (Join-Path $dir ".$base.open-decisions-cursor")
}

# Cheap identity for the "is the file at this path still the same file"
# invalidation. The bash library uses dev:inode from `stat`; .NET exposes
# neither portably, and creation time is not a stable birth time on every
# filesystem. The port hashes the ALREADY-CONSUMED prefix instead - the first
# min(offset, 1 KiB) bytes - which is exactly the region an append-only status
# file never rewrites, so a normal append leaves the identity unchanged while a
# recreated or rotated file at the same path almost certainly changes it. Cost
# is one bounded 1 KiB read.
#
# A recreated file whose first kilobyte is byte-identical is not detected, the
# same class of deliberately accepted gap as the bash version's same-inode
# in-place edit: no firstmate code path ever rewrites a status file in place,
# and the cursor is safe to delete, which forces one full re-fold.
function Get-FmClassifyFileIdent {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Length
    )
    $want = [int][Math]::Min($Length, 1024)
    if ($want -le 0) { return 'prefix:empty' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch {
        return ''
    }
    try {
        $buffer = [byte[]]::new($want)
        $read = 0
        while ($read -lt $want) {
            $n = $stream.Read($buffer, $read, $want - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt $want) { return '' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($buffer, 0, $read) } finally { $sha.Dispose() }
        return 'prefix:' + [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 32).ToLowerInvariant()
    } catch {
        return ''
    } finally {
        $stream.Dispose()
    }
}

function Read-FmClassifyCursor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CursorPath)
    $blank = [pscustomobject]@{ Version = ''; Offset = 0; Ident = ''; OpenLines = @() }
    if (-not (Test-FmLifecycleRegularFile -Path $CursorPath)) { return $blank }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($CursorPath) } catch { return $blank }
    $lines = ($text -replace "`r`n", "`n").Split("`n")
    if ($lines.Count -lt 3) { return $blank }
    if (-not $lines[0].StartsWith('version=')) { return $blank }
    $version = $lines[0].Substring('version='.Length)
    if ($version -ne "$script:FmOpenDecisionsFoldVersion") { return $blank }
    if (-not $lines[1].StartsWith('offset=')) { return $blank }
    $offsetRaw = $lines[1].Substring('offset='.Length)
    if ($offsetRaw -notmatch '^[0-9]+$') { return $blank }
    if (-not $lines[2].StartsWith('ident=')) { return $blank }
    $ident = $lines[2].Substring('ident='.Length)
    if ($ident -eq '') { return $blank }
    $open = @()
    if ($lines.Count -gt 3) {
        $open = @($lines[3..($lines.Count - 1)] | Where-Object { $_ -ne '' })
    }
    return [pscustomobject]@{ Version = $version; Offset = [long]$offsetRaw; Ident = $ident; OpenLines = $open }
}

function Write-FmClassifyCursor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CursorPath,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ident,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$OpenSet
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("version=$script:FmOpenDecisionsFoldVersion`n")
    [void]$sb.Append("offset=$Offset`n")
    [void]$sb.Append("ident=$Ident`n")
    foreach ($record in $OpenSet) { [void]$sb.Append($record.Line + "`n") }
    # Temp file plus replace, so a crash leaves either the prior cursor or the
    # new one and never a partial record.
    $tmp = "$CursorPath.tmp.$PID"
    try {
        Write-FmTextFileLf -Path $tmp -Text $sb.ToString()
        Move-Item -LiteralPath $tmp -Destination $CursorPath -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Decode the bytes appended since <Offset>. Returns $null on an I/O failure so
# the caller can report its already-trusted persisted set unchanged instead of
# wiping it.
function Read-FmClassifyStatusChunk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][long]$Size
    )
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    } catch {
        return $null
    }
    try {
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $count = [int]($Size - $Offset)
        $buffer = [byte[]]::new($count)
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($buffer, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return [pscustomobject]@{
            Text  = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            Bytes = $read
        }
    } catch {
        return $null
    } finally {
        $stream.Dispose()
    }
}
