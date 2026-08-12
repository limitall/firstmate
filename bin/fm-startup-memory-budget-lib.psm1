# fm-startup-memory-budget-lib.psm1 - startup-memory budget primitives.
# Twin: bin/fm-startup-memory-budget-lib.sh
#
# The local, primary-authoritative config/startup-memory-budget setting is one
# strictly formatted positive decimal value followed by one newline. The locked
# primary bootstrap owns first materialization. This library owns safe parsing,
# default publication, and the portable prompt-memory estimate used by
# bin/fm-startup-memory-budget and the internal /stow skill.
#
# bash -> PowerShell:
#   FM_STARTUP_MEMORY_BUDGET_FILE                -> Get-FmStartupMemoryBudgetFileName
#   FM_STARTUP_MEMORY_BUDGET_DEFAULT             -> Get-FmStartupMemoryBudgetDefault
#   FM_STARTUP_MEMORY_BUDGET_ERROR               -> Get-FmStartupMemoryBudgetError
#   FM_STARTUP_MEMORY_BUDGET_VALUE               -> Get-FmStartupMemoryBudgetValue
#   fm_startup_memory_budget_fail                -> Write-FmStartupMemoryBudgetFailure
#   fm_startup_memory_budget_link_count          -> Get-FmStartupMemoryBudgetLinkCount
#   fm_startup_memory_budget_config_dir_safe     -> Test-FmStartupMemoryBudgetConfigDir
#   fm_startup_memory_budget_file_valid          -> Test-FmStartupMemoryBudgetFile
#   fm_startup_memory_budget_read                -> Get-FmStartupMemoryBudget
#   fm_startup_memory_budget_materialize         -> Initialize-FmStartupMemoryBudget
#   fm_startup_memory_estimated_tokens_for_bytes -> Get-FmStartupMemoryEstimatedToken
#   fm_startup_memory_measure_file               -> Measure-FmStartupMemoryFile
#   fm_startup_memory_decimal_le                 -> Test-FmStartupMemoryDecimalLe
#
# ---------------------------------------------------------------------------
# Integer math: every comparison here is explicitly typed
# ---------------------------------------------------------------------------
# PowerShell's `-gt`/`-le` between two STRINGS is a string comparison, so
# '10' -gt '9' is $false. Every numeric decision below therefore casts to
# [long] first, or - for Test-FmStartupMemoryDecimalLe - deliberately compares
# strings by LENGTH then lexically, which is what the bash does and is exactly
# why it exists: the budget totals can exceed shell arithmetic range, so that
# one function must never convert to a number at all.
#
# ---------------------------------------------------------------------------
# The hard-link check, and what "link count" means on Windows
# ---------------------------------------------------------------------------
# The bash asks stat(1) for a link count and rejects anything but 1: a second
# hard link is a second name through which a "private" setting could be
# rewritten. MSYS stat answers correctly on NTFS (verified: 1 before `ln`, 2
# after), so this is a LIVE check on Windows, not a vestigial one.
#
# .NET exposes no link count, but the PowerShell FileSystem provider exposes
# LinkType, which reads 'HardLink' exactly when the count exceeds 1 (verified
# on the same fixtures). Since the bash only ever tests `!= 1`, that boolean
# is the whole question. Get-FmStartupMemoryBudgetLinkCount therefore returns
# 1 or 2 - "one link" or "more than one" - and NOT a true count. It is named
# for its twin so the pairing stays greppable; the value is only ever compared
# against 1.
#
# ---------------------------------------------------------------------------
# Publication: CreateNew replaces mktemp + link + unlink
# ---------------------------------------------------------------------------
# The bash publishes the default with `umask 077; mktemp` then `ln tmp path`
# then `rm tmp`, because link(2) is its no-clobber primitive and removing the
# temporary name leaves exactly one link. PowerShell has a direct no-clobber
# primitive - opening with FileMode.CreateNew, which fails if the path exists -
# so the temp file, the link, and the unlink all disappear while the published
# ARTIFACT is byte-identical and single-linked. A losing race still falls
# through to the same "accept it only if it now meets the exact format" read,
# never a replacement.
#
# The `umask 077` has no twin: on Windows chmod is inert, and per
# docs/powershell-port.md the PowerShell side must NOT enforce real ACLs where
# the bash cannot, or the two worlds would disagree about the same file.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmStartupMemoryBudgetFile = 'startup-memory-budget'
$script:FmStartupMemoryBudgetDefault = '7500'
$script:FmStartupMemoryBudgetError = ''
$script:FmStartupMemoryBudgetValue = ''

<#
.SYNOPSIS
The config file name this library owns.
#>
function Get-FmStartupMemoryBudgetFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmStartupMemoryBudgetFile
}

<#
.SYNOPSIS
The visible default budget, in estimated tokens.
#>
function Get-FmStartupMemoryBudgetDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmStartupMemoryBudgetDefault
}

<#
.SYNOPSIS
The most recent failure reason recorded by this library.
.DESCRIPTION
The twin of the FM_STARTUP_MEMORY_BUDGET_ERROR out-global. A module cannot
write into its caller's scope, so the value lives at module scope and is read
back through this accessor after a function returns $false.
#>
function Get-FmStartupMemoryBudgetError {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmStartupMemoryBudgetError
}

<#
.SYNOPSIS
The value captured by the most recent successful Test-FmStartupMemoryBudgetFile.
#>
function Get-FmStartupMemoryBudgetValue {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmStartupMemoryBudgetValue
}

<#
.SYNOPSIS
Record a failure reason and answer $false, the fm_startup_memory_budget_fail twin.
#>
function Write-FmStartupMemoryBudgetFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    $script:FmStartupMemoryBudgetError = $Message
    return $false
}

<#
.SYNOPSIS
1 when a file has exactly one hard link, 2 when it has more, $null when the
file cannot be inspected.
.DESCRIPTION
See the header: this is a two-valued answer wearing a count's name, because
the only question its caller asks is "is this != 1".
#>
function Get-FmStartupMemoryBudgetLinkCount {
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        if ($item.LinkType -eq 'HardLink') { return 2 }
        return 1
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
True when a config directory is a real, unlinked directory.
.DESCRIPTION
The symlink test comes FIRST and is separate from the directory test, exactly
as in the bash: a link to a directory would satisfy `-d` while still letting
the settings this library validates be redirected somewhere else.
#>
function Test-FmStartupMemoryBudgetConfigDir {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $native = ConvertTo-FmNativePath $Directory
    if (Test-FmSymlink $native) {
        return (Write-FmStartupMemoryBudgetFailure 'config directory is symlinked')
    }
    if (-not (Test-Path -LiteralPath $native -PathType Container)) {
        return (Write-FmStartupMemoryBudgetFailure 'config directory is not a directory')
    }
    return $true
}

<#
.SYNOPSIS
True for a regular, single-linked file holding exactly one positive decimal
value and one terminating newline; records the value on success.
.DESCRIPTION
Every rejection reason is distinct because bin/fm-config-inherit surfaces them
when propagating inherited material, and "it is wrong" is not actionable.

Two byte-level details are deliberate:
  - The bytes are decoded WITHOUT byte-order-mark stripping. File.ReadAllText
    would silently swallow a leading BOM and let a BOM-prefixed 7500 validate,
    where the bash sees three stray bytes and rejects it.
  - Only trailing LINE FEEDS are trimmed before the digit test, matching
    `$(<file)`. A CRLF file therefore leaves a \r in the value and fails the
    digit test in both worlds, rather than being quietly normalized here.
#>
function Test-FmStartupMemoryBudgetFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $script:FmStartupMemoryBudgetValue = ''
    $native = ConvertTo-FmNativePath $Path

    if (Test-FmSymlink $native) {
        return (Write-FmStartupMemoryBudgetFailure 'file is symlinked')
    }
    if (-not (Test-Path -LiteralPath $native)) {
        return (Write-FmStartupMemoryBudgetFailure 'file is absent')
    }
    if (-not [System.IO.File]::Exists($native)) {
        return (Write-FmStartupMemoryBudgetFailure 'file is not a regular file')
    }

    $links = Get-FmStartupMemoryBudgetLinkCount -Path $native
    if ($null -eq $links) {
        return (Write-FmStartupMemoryBudgetFailure 'could not inspect file link count')
    }
    if ($links -ne 1) {
        return (Write-FmStartupMemoryBudgetFailure 'file is hardlinked')
    }

    try {
        $raw = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($native))
    } catch {
        return (Write-FmStartupMemoryBudgetFailure 'could not read file')
    }

    $value = $raw.TrimEnd("`n")
    # bash: case "$value" in ''|0|*[!0-9]*|0*) - empty, any non-digit, or a
    # leading zero (which covers the bare "0" too).
    if ($value -eq '' -or $value -match '[^0-9]' -or $value.StartsWith('0')) {
        return (Write-FmStartupMemoryBudgetFailure 'value must be one positive decimal integer')
    }
    # The `printf '%s\n' "$value" | cmp -s "$path" -` twin: the file must be
    # the value and ONE newline, so a second blank line or a missing
    # terminator is a format error rather than a tolerated variation.
    if ($raw -ne ($value + "`n")) {
        return (Write-FmStartupMemoryBudgetFailure 'file must contain exactly one value followed by one newline')
    }

    $script:FmStartupMemoryBudgetValue = $value
    return $true
}

<#
.SYNOPSIS
The validated budget value for a config directory, or $null.
.DESCRIPTION
Never treats an absent or unsafe file as an implicit default, because callers
need a visible, auditable setting rather than one this library invented.
#>
function Get-FmStartupMemoryBudget {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    if (-not (Test-FmStartupMemoryBudgetConfigDir -Directory $ConfigDir)) { return $null }
    $path = Join-Path (ConvertTo-FmNativePath $ConfigDir) $script:FmStartupMemoryBudgetFile
    if (-not (Test-FmStartupMemoryBudgetFile -Path $path)) { return $null }
    return $script:FmStartupMemoryBudgetValue
}

<#
.SYNOPSIS
Publish the visible default when the file is absent; validate what is there
otherwise. True when the directory ends up holding a valid budget.
.DESCRIPTION
A concurrent valid creator is accepted; every unsafe or malformed existing
artifact is rejected WITHOUT replacement, because overwriting a file this
library cannot understand would destroy an operator's deliberate setting.

The final answer always comes from a validating read, never from "the write
succeeded", so a published file that somehow fails its own format check is
reported as a failure rather than assumed good.
#>
function Initialize-FmStartupMemoryBudget {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    $nativeDir = ConvertTo-FmNativePath $ConfigDir
    if ((Test-Path -LiteralPath $nativeDir) -or (Test-FmSymlink $nativeDir)) {
        if (-not (Test-FmStartupMemoryBudgetConfigDir -Directory $nativeDir)) { return $false }
    } else {
        try {
            [void][System.IO.Directory]::CreateDirectory($nativeDir)
        } catch {
            return (Write-FmStartupMemoryBudgetFailure 'could not create config directory')
        }
        if (-not (Test-FmStartupMemoryBudgetConfigDir -Directory $nativeDir)) { return $false }
    }

    $path = Join-Path $nativeDir $script:FmStartupMemoryBudgetFile
    if ((Test-Path -LiteralPath $path) -or (Test-FmSymlink $path)) {
        return ($null -ne (Get-FmStartupMemoryBudget -ConfigDir $nativeDir))
    }

    # FileMode.CreateNew is the no-clobber claim: it throws rather than
    # truncating if another actor won the race, which is the same guarantee
    # link(2) gives the bash twin.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:FmStartupMemoryBudgetDefault + "`n")
    $published = $false
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $published = $true
        } finally {
            $stream.Dispose()
        }
    } catch [System.IO.IOException] {
        # Lost the race: another actor created it between the check and here.
        # Fall through to the validating read, exactly as the bash does after
        # a failed `ln`. Verbose rather than silent so the race is observable
        # when someone goes looking, without becoming operator-facing noise.
        Write-Verbose "startup-memory budget already published by another actor: $($_.Exception.Message)"
    } catch {
        return (Write-FmStartupMemoryBudgetFailure 'could not create default temporary file')
    }

    if ($published -and -not (Test-FmStartupMemoryBudgetFile -Path $path)) {
        # A file we just wrote that does not validate is not something to keep.
        # A failed cleanup must not mask the validation failure being reported.
        try {
            [System.IO.File]::Delete($path)
        } catch {
            Write-Verbose "could not remove the unpublishable default: $($_.Exception.Message)"
        }
        if ($script:FmStartupMemoryBudgetError -eq '') {
            [void](Write-FmStartupMemoryBudgetFailure 'could not write default value')
        }
        return $false
    }

    return ($null -ne (Get-FmStartupMemoryBudget -ConfigDir $nativeDir))
}

<#
.SYNOPSIS
ceil(bytes / 3) as a decimal string, or $null for a non-numeric input.
.DESCRIPTION
Stable, dependency-free, and deliberately conservative for ordinary prompt
text without claiming provider exactness. [long] arithmetic, not PowerShell's
implicit coercion, so a large measurement cannot silently become a double and
come back with an exponent in it.
#>
function Get-FmStartupMemoryEstimatedToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Bytes)

    if ($Bytes -eq '' -or $Bytes -match '[^0-9]') { return $null }
    [long]$value = 0
    if (-not [long]::TryParse($Bytes, [ref]$value)) { return $null }
    [long]$tokens = [long][Math]::Floor($value / 3)
    if (($value % 3) -ne 0) { $tokens = $tokens + 1 }
    return $tokens.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
Measure one memory file: bytes, estimated tokens, and present/absent.
.DESCRIPTION
Returns an object whose Text field is the exact line the bash prints
("<bytes> <tokens> <present|absent>"), alongside the parsed Bytes/Tokens/
Presence fields that were the bash's three out-globals.

Memory files must be ordinary files when present, so a measurement never
follows a symlink or reads a special file. A DANGLING symlink is "present but
not ordinary" - an error - rather than "absent", which is why existence is
tested as `-e OR -L` before the ordinary-file test.

$null is returned on failure, with the reason in Get-FmStartupMemoryBudgetError.
#>
function Measure-FmStartupMemoryFile {
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    $exists = (Test-Path -LiteralPath $native) -or (Test-FmSymlink $native)
    if (-not $exists) {
        return [pscustomobject]@{ Bytes = '0'; Tokens = '0'; Presence = 'absent'; Text = '0 0 absent' }
    }
    if ((Test-FmSymlink $native) -or (-not [System.IO.File]::Exists($native))) {
        [void](Write-FmStartupMemoryBudgetFailure "memory file is not an ordinary regular file: $Path")
        return $null
    }

    try {
        $bytes = ([System.IO.FileInfo]::new($native)).Length
    } catch {
        [void](Write-FmStartupMemoryBudgetFailure "could not measure memory file: $Path")
        return $null
    }
    $bytesText = ([long]$bytes).ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $tokens = Get-FmStartupMemoryEstimatedToken -Bytes $bytesText
    if ($null -eq $tokens) {
        [void](Write-FmStartupMemoryBudgetFailure "could not estimate memory tokens for: $Path")
        return $null
    }
    return [pscustomobject]@{
        Bytes    = $bytesText
        Tokens   = $tokens
        Presence = 'present'
        Text     = "$bytesText $tokens present"
    }
}

<#
.SYNOPSIS
True when the decimal string Left is less than or equal to Right.
.DESCRIPTION
Decimal comparison WITHOUT arithmetic, so a total larger than the shell's
integer range still compares correctly - which is the entire reason the bash
version exists and why converting this to [long] here would be a regression,
not a cleanup.

The input guard is the twin of `case "$left:$right" in *[!0-9:]*|:*|*: )`,
composed string and all. That composition has a quirk worth naming rather than
"fixing": an input that itself contains ':' passes the character test and is
then rejected by the length/lexical comparison instead. Reproducing the quirk
keeps the two worlds' verdicts identical on every input.
#>
function Test-FmStartupMemoryDecimalLe {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Right
    )

    $composed = "${Left}:${Right}"
    if ($composed -match '[^0-9:]') { return $false }
    if ($composed.StartsWith(':') -or $composed.EndsWith(':')) { return $false }

    if ($Left.Length -lt $Right.Length) { return $true }
    if ($Left.Length -gt $Right.Length) { return $false }
    if ($Left -eq $Right) { return $true }
    # Equal-length digit strings: ordinal comparison IS numeric comparison.
    # Ordinal, not culture-aware, so a host locale cannot reorder digits.
    return ([string]::CompareOrdinal($Left, $Right) -lt 0)
}

Export-ModuleMember -Function @(
    'Get-FmStartupMemoryBudgetFileName',
    'Get-FmStartupMemoryBudgetDefault',
    'Get-FmStartupMemoryBudgetError',
    'Get-FmStartupMemoryBudgetValue',
    'Write-FmStartupMemoryBudgetFailure',
    'Get-FmStartupMemoryBudgetLinkCount',
    'Test-FmStartupMemoryBudgetConfigDir',
    'Test-FmStartupMemoryBudgetFile',
    'Get-FmStartupMemoryBudget',
    'Initialize-FmStartupMemoryBudget',
    'Get-FmStartupMemoryEstimatedToken',
    'Measure-FmStartupMemoryFile',
    'Test-FmStartupMemoryDecimalLe'
)
