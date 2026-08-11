<#
    FmState - reading and writing firstmate state files.

    THE highest-risk file in this port, and deliberately the only place that
    touches state-file bytes.

    Why it exists at all: on Linux a reader sails straight through a file another
    process is writing, so the bash original can `cat` and `>>` anywhere it likes.
    Windows does not work that way. A file opened by another process can refuse
    the open outright with a sharing violation, and a file pending deletion
    refuses with an access violation. Both are TRANSIENT - the correct response is
    to back off and try again, not to fail the operation and not to report the
    file as absent. Scattering that discipline across the port would guarantee
    some caller forgets it, so every read, write, append and delete in the whole
    module goes through Invoke-FmFileRetry here.

    File contracts preserved byte for byte, so a Linux firstmate and this one read
    each other's files (AGENTS.md section 2):
      - UTF-8 with NO byte order mark. A BOM would corrupt the first field of the
        first line for every bash reader.
      - LF line endings, never CRLF. PowerShell's own Set-Content/Out-File write
        CRLF on Windows, which is exactly why nothing here uses them.
      - A line-oriented file ends with a trailing LF, matching printf '%s\n'.
      - Reads TOLERATE what they must never write: a CRLF file or a leading BOM
        left by some other tool is parsed correctly rather than rejected.

    Publication is atomic: content is written to a temp file in the SAME directory
    and then moved over the destination, so no reader - on either platform - ever
    observes a half-written state file. A crash leaves the temp file, never a
    truncated record.
#>

Set-StrictMode -Version Latest

# Retry budget. Defaults give ~12 attempts over roughly 1.3s of backoff, which
# comfortably covers a competing writer's atomic replace while still failing in
# human time when a file is genuinely held (an editor, an antivirus scan).
# Overridable per home for a slow or heavily scanned filesystem.
$script:FmStateRetryDefaults = @{
    Attempts     = 12
    DelayMs      = 10
    MaxDelayMs   = 200
}

# Cumulative retry counter. Not exported: it exists so tests (and a future
# diagnostic) can prove the backoff path actually ran rather than inferring it
# from timing.
$script:FmStateRetryTotal = 0

function Get-FmStateRetrySetting {
    param([Parameter(Mandatory)][ValidateSet('Attempts', 'DelayMs', 'MaxDelayMs')][string]$Name)

    $envName = switch ($Name) {
        'Attempts' { 'FM_STATE_RETRY_ATTEMPTS' }
        'DelayMs' { 'FM_STATE_RETRY_DELAY_MS' }
        'MaxDelayMs' { 'FM_STATE_RETRY_MAX_DELAY_MS' }
    }
    $raw = [System.Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    }
    return $script:FmStateRetryDefaults[$Name]
}

function Test-FmTransientIOException {
    <#
        .SYNOPSIS
        True when an exception is a retryable Windows file-sharing condition.

        .DESCRIPTION
        Retryable: a plain IOException (a sharing violation is one, HRESULT
        0x80070020) and UnauthorizedAccessException (raised for a file pending
        delete, and by scanners that hold a handle with no sharing).

        NOT retryable, even though they derive from IOException: file not found,
        directory not found, and path too long. Retrying those only delays a
        deterministic failure.

        The walk descends InnerException because a .NET call made from
        PowerShell surfaces as a MethodInvocationException wrapping the real one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][System.Exception]$Exception)

    $current = $Exception
    for ($depth = 0; $current -and $depth -lt 8; $depth++) {
        if ($current -is [System.IO.FileNotFoundException] -or
            $current -is [System.IO.DirectoryNotFoundException] -or
            $current -is [System.IO.PathTooLongException]) {
            return $false
        }
        if ($current -is [System.UnauthorizedAccessException]) { return $true }
        if ($current -is [System.IO.IOException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-FmFileRetry {
    <#
        .SYNOPSIS
        Run a file operation, retrying transient Windows sharing failures with
        exponential backoff and jitter.

        .DESCRIPTION
        The one retry discipline for the whole module. A non-transient failure
        (missing directory, bad path, a bug) is rethrown immediately and
        unchanged; only a transient sharing condition is retried. When the budget
        is exhausted the original exception is wrapped in an IOException that
        names the operation, the path and the attempt count, so an exhausted
        retry is never mistaken for a first-try failure.

        Jitter matters: two processes that collide and then back off on identical
        schedules collide again. Each delay is randomized across its own window.

        .EXAMPLE
        Invoke-FmFileRetry -Operation 'read' -Path $p -Action { [IO.File]::ReadAllText($p) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Operation = 'file operation',
        [string]$Path = '',
        [ValidateRange(0, 1000)][int]$Attempts = 0,
        [ValidateRange(0, 60000)][int]$DelayMilliseconds = 0,
        [ValidateRange(0, 60000)][int]$MaxDelayMilliseconds = 0
    )

    if ($Attempts -le 0) { $Attempts = Get-FmStateRetrySetting -Name 'Attempts' }
    if ($DelayMilliseconds -le 0) { $DelayMilliseconds = Get-FmStateRetrySetting -Name 'DelayMs' }
    if ($MaxDelayMilliseconds -le 0) { $MaxDelayMilliseconds = Get-FmStateRetrySetting -Name 'MaxDelayMs' }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Action
        } catch {
            $exception = $_.Exception
            if (-not (Test-FmTransientIOException -Exception $exception)) { throw }
            if ($attempt -ge $Attempts) {
                throw [System.IO.IOException]::new(
                    "firstmate: $Operation failed after $Attempts attempts on '$Path': $($exception.Message)",
                    $exception)
            }
            $script:FmStateRetryTotal++
            $window = [Math]::Min($MaxDelayMilliseconds, $DelayMilliseconds * [Math]::Pow(2, $attempt - 1))
            $delay = [int][Math]::Max(1, (Get-Random -Minimum ($window / 2) -Maximum ($window + 1)))
            Write-Verbose "firstmate: retrying $Operation on '$Path' (attempt $attempt of $Attempts) after ${delay}ms"
            Start-Sleep -Milliseconds $delay
        }
    }
}

function New-FmDirectory {
    <#
        .SYNOPSIS
        Ensure a directory exists, tolerating a concurrent creator.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ([System.IO.Directory]::Exists($Path)) { return }
    Invoke-FmFileRetry -Operation 'create directory' -Path $Path -Action {
        $null = [System.IO.Directory]::CreateDirectory($Path)
    }
}

function ConvertTo-FmStateText {
    <#
        .SYNOPSIS
        Normalize text to the on-disk contract: LF endings, trailing LF.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [switch]$NoTrailingNewline
    )
    if ($null -eq $Text) { $Text = '' }
    $normalized = $Text -replace "`r`n", "`n"
    if ($NoTrailingNewline -or $normalized.Length -eq 0) { return $normalized }
    if (-not $normalized.EndsWith("`n")) { $normalized += "`n" }
    return $normalized
}

function Get-FmStateTempPath {
    <#
        .SYNOPSIS
        Unique temp path beside the destination, for the write-then-move publish.

        .DESCRIPTION
        Same directory as the destination on purpose: a move across volumes is a
        copy, and a copy is not atomic. The leading dot keeps the temp out of the
        way of anything scanning state/ for task records.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileName($Path)
    $unique = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return (Join-Path $directory ".$name.tmp.$PID.$unique")
}

function Read-FmStateFile {
    <#
        .SYNOPSIS
        Read a state file's text, or $null when it does not exist.

        .DESCRIPTION
        Missing is not an error - it is the answer, matching `cat 2>/dev/null`
        in the bash original. An EMPTY file returns '' and is deliberately
        distinguishable from a missing one, because for several firstmate records
        (an absent captain.md versus an empty one) that difference is meaningful.

        The file is opened with FileShare.ReadWrite|Delete: on Windows this is
        what lets the read succeed while another process holds the file open for
        writing or has it pending delete. A sharing violation from a writer that
        allows nothing is still retried by Invoke-FmFileRetry.

        A leading UTF-8 BOM is stripped on read. This module never writes one, but
        a file touched by another Windows tool may carry one and the bash side
        would choke on it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FmFullPath -Path $Path
    $bytes = Invoke-FmFileRetry -Operation 'read state file' -Path $full -Action {
        if (-not [System.IO.File]::Exists($full)) { return $null }
        $stream = [System.IO.File]::Open(
            $full,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $buffer = [System.IO.MemoryStream]::new()
            try {
                $stream.CopyTo($buffer)
                return , $buffer.ToArray()
            } finally { $buffer.Dispose() }
        } finally { $stream.Dispose() }
    }

    if ($null -eq $bytes) { return $null }
    if ($bytes.Length -eq 0) { return '' }
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    return [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Read-FmStateLines {
    <#
        .SYNOPSIS
        Read a state file as lines, without terminators. Empty array when missing.

        .DESCRIPTION
        Tolerates CRLF from a foreign writer by trimming a trailing CR from each
        line, and drops the empty element produced by the file's final LF. A blank
        line INSIDE the file is preserved - some records use one meaningfully.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)

    $text = Read-FmStateFile -Path $Path
    if ($null -eq $text -or $text.Length -eq 0) { return @() }
    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    return @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
}

function Write-FmStateFile {
    <#
        .SYNOPSIS
        Publish a state file atomically: UTF-8 without BOM, LF endings.

        .DESCRIPTION
        Writes to a temp file in the same directory, flushes it to disk, then
        moves it over the destination. A reader either sees the whole previous
        file or the whole new one, never a mix, on either platform. A crash
        mid-write leaves the temp file behind and the destination untouched.

        The trailing newline is added automatically for non-empty content;
        -NoTrailingNewline is for the rare record that must not have one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Content,
        [switch]$NoTrailingNewline
    )

    $full = Resolve-FmFullPath -Path $Path
    if (-not $PSCmdlet.ShouldProcess($full, 'Write state file')) { return }

    New-FmDirectory -Path ([System.IO.Path]::GetDirectoryName($full))
    $text = ConvertTo-FmStateText -Text $Content -NoTrailingNewline:$NoTrailingNewline
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    $temp = Get-FmStateTempPath -Path $full

    try {
        Invoke-FmFileRetry -Operation 'write state file' -Path $temp -Action {
            try {
                $stream = [System.IO.File]::Open(
                    $temp,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
                try {
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush($true)
                } finally { $stream.Dispose() }
            } catch {
                # Leave no half-written temp behind for the next attempt to trip
                # over: CreateNew would then fail on its own leftover forever.
                try { [System.IO.File]::Delete($temp) } catch { }
                throw
            }
        }
        Invoke-FmFileRetry -Operation 'publish state file' -Path $full -Action {
            [System.IO.File]::Move($temp, $full, $true)
        }
    } catch {
        try { [System.IO.File]::Delete($temp) } catch { }
        throw
    }
}

function Write-FmStateLines {
    <#
        .SYNOPSIS
        Publish a state file from lines, atomically, one LF-terminated line each.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][AllowNull()][string[]]$Line
    )

    $lines = @()
    if ($Line) { $lines = @($Line) }
    foreach ($item in $lines) { Assert-FmSingleLine -Text $item -Label 'line' }
    $content = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
    Write-FmStateFile -Path $Path -Content $content
}

function Assert-FmSingleLine {
    <#
        .SYNOPSIS
        Throw when text carries a CR or LF that would corrupt a line-oriented file.

        .DESCRIPTION
        Fail closed rather than silently mangling: a status line or wake record
        that smuggles a newline splits into two records for every reader, and the
        damage is durable. Callers that legitimately need to flatten a value do it
        deliberately before calling.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [string]$Label = 'value'
    )
    if ($null -eq $Text) { return }
    if ($Text -match "[`r`n]") {
        throw [System.ArgumentException]::new(
            "firstmate: $Label must not contain a carriage return or line feed: '$Text'")
    }
}

function Add-FmStateLine {
    <#
        .SYNOPSIS
        Append LF-terminated lines to a state file, creating it when absent.

        .DESCRIPTION
        Append, not read-modify-write: state/<id>.status is an append-only wake
        event log that several processes write concurrently, and a
        read-modify-write would silently drop a competitor's line. Each call
        writes in one Write to an append-mode handle, which the OS keeps atomic
        for the short records firstmate appends.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line
    )

    $full = Resolve-FmFullPath -Path $Path
    foreach ($item in $Line) { Assert-FmSingleLine -Text $item -Label 'appended line' }
    if (-not $PSCmdlet.ShouldProcess($full, 'Append to state file')) { return }

    New-FmDirectory -Path ([System.IO.Path]::GetDirectoryName($full))
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((($Line -join "`n") + "`n"))

    Invoke-FmFileRetry -Operation 'append state line' -Path $full -Action {
        $stream = [System.IO.File]::Open(
            $full,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
    }
}

function Remove-FmStateFile {
    <#
        .SYNOPSIS
        Delete a state file. Absent is success; a held file is retried.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FmFullPath -Path $Path
    if (-not [System.IO.File]::Exists($full)) { return }
    if (-not $PSCmdlet.ShouldProcess($full, 'Remove state file')) { return }
    Invoke-FmFileRetry -Operation 'remove state file' -Path $full -Action {
        [System.IO.File]::Delete($full)
    }
}

function Get-FmPathMtime {
    <#
        .SYNOPSIS
        Last write time (UTC) of a path, or $null when it does not exist.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FmFullPath -Path $Path
    if (-not ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full))) { return $null }
    try {
        if ([System.IO.Directory]::Exists($full)) { return [System.IO.Directory]::GetLastWriteTimeUtc($full) }
        return [System.IO.File]::GetLastWriteTimeUtc($full)
    } catch {
        return $null
    }
}

function Get-FmPathAge {
    <#
        .SYNOPSIS
        Age of a path in whole seconds; 999999 when it cannot be read.

        .DESCRIPTION
        The 999999 sentinel is fm_path_age's contract from bin/fm-wake-lib.sh,
        kept because every caller compares the age against a threshold and an
        unreadable path must read as "very old", never as "brand new". Negative
        ages (a clock step, a file stamped in the future) are clamped to 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)

    $mtime = Get-FmPathMtime -Path $Path
    if ($null -eq $mtime) { return 999999 }
    $seconds = [int][Math]::Floor(([datetime]::UtcNow - $mtime).TotalSeconds)
    if ($seconds -lt 0) { return 0 }
    return $seconds
}

function Read-FmKeyValueFile {
    <#
        .SYNOPSIS
        Parse a key=value record (state/<id>.meta and friends) into an ordered map.

        .DESCRIPTION
        Splits on the FIRST '=' only, so a value containing '=' survives intact -
        the same as `cut -d= -f2-`. A line with no '=' is ignored, matching the
        bash readers' `grep '^key='`. On a duplicated key the LAST value wins,
        while the key keeps its first position. Returns an empty map for a missing
        file, never $null, so callers can index without a null check.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $fields = [ordered]@{}
    foreach ($line in (Read-FmStateLines -Path $Path)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { continue }
        $key = $line.Substring(0, $index)
        $value = $line.Substring($index + 1)
        $fields[$key] = $value
    }
    return $fields
}

function Assert-FmKeyValueField {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value
    )
    if ([string]::IsNullOrEmpty($Name)) {
        throw [System.ArgumentException]::new('firstmate: key=value field name must not be empty', 'Name')
    }
    if ($Name -match '[=\s]') {
        throw [System.ArgumentException]::new(
            "firstmate: key=value field name must not contain '=' or whitespace: '$Name'", 'Name')
    }
    Assert-FmSingleLine -Text $Value -Label "value of field '$Name'"
}

function Write-FmKeyValueFile {
    <#
        .SYNOPSIS
        Publish a key=value record atomically, in the map's own order.

        .DESCRIPTION
        Field order is the caller's, because firstmate's records are read by
        humans and by bash and both expect a stable field order. Use an ordered
        dictionary; a plain hashtable does not promise one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Fields.Keys) {
        $value = if ($null -eq $Fields[$key]) { '' } else { [string]$Fields[$key] }
        Assert-FmKeyValueField -Name ([string]$key) -Value $value
        $lines.Add("$key=$value")
    }
    Write-FmStateLines -Path $Path -Line $lines.ToArray()
}

function Set-FmKeyValueField {
    <#
        .SYNOPSIS
        Set or remove one field of a key=value record, preserving every other line.

        .DESCRIPTION
        Read-modify-write of the whole record, published atomically. An existing
        field is replaced IN PLACE, keeping field order stable; a new field is
        appended; duplicates of the target key collapse to one. Unknown fields
        written by another tool are carried through untouched, which is what makes
        this safe to use against a record whose full schema this port does not own.

        It does NOT lock: a record with more than one writer must be updated
        inside Invoke-FmWithLock on Get-FmMetaLockPath, exactly as fm-spawn.sh
        holds the meta lock across its own read-modify-write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Value,
        [switch]$Remove
    )

    if (-not $Remove) { Assert-FmKeyValueField -Name $Name -Value $Value }

    $existing = Read-FmStateLines -Path $Path
    $output = [System.Collections.Generic.List[string]]::new()
    $written = $false
    foreach ($line in $existing) {
        $index = $line.IndexOf('=')
        $key = if ($index -lt 1) { $null } else { $line.Substring(0, $index) }
        if ($key -cne $Name) {
            $output.Add($line)
            continue
        }
        if ($Remove -or $written) { continue }
        $output.Add("$Name=$Value")
        $written = $true
    }
    if (-not $Remove -and -not $written) { $output.Add("$Name=$Value") }

    Write-FmStateLines -Path $Path -Line $output.ToArray()
}
