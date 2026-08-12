# fm-common.psm1 - the foundation every firstmate PowerShell script imports.
# Twin: no single bash file; this module consolidates the boilerplate that the
# bash tree repeats at the top of ~90 scripts (root/home/state resolution, the
# say/die reporters, meta accessors) plus the Windows-native primitives that
# bash got for free from its POSIX runtime.
#
# docs/powershell-port.md owns the conversion contracts this module enforces.
# The three that shape every function here, each verified empirically on a real
# Windows 11 + PowerShell 7.6.4 host before being written down:
#
#   1. OUTPUT MUST BE LF, AND UTF-8 WITHOUT A BOM.
#      `Write-Output "a"` emits "a\r\n" (verified: od shows 61 0d 0a). Every
#      state file, wake-queue record, and captured-stdout comparison in this
#      repo is byte-sensitive, and a stray \r silently corrupts TAB/field
#      parsing downstream - exactly the class of bug that cost hours during the
#      Windows bash port (native jq's CRLF pipe output). So NOTHING in a
#      firstmate PowerShell script may use Write-Output/Write-Host for real
#      output; Write-FmOut and Write-FmErr are the only sanctioned writers.
#      Encoding matters just as much: without an explicit UTF-8 console
#      encoding, `[Console]::Out.Write("❯")` emits "?" (verified), which would
#      destroy the composer glyph vocabulary (❯ › in fm-composer-lib) and the
#      U+2063 INVISIBLE SEPARATOR that prefixes every operational input.
#
#   2. .NET DOES NOT UNDERSTAND MSYS PATHS.
#      [System.IO.File]::WriteAllText('/tmp/x', ...) throws "Could not find a
#      part of the path 'C:\tmp\x'" (verified) - it resolves POSIX-looking
#      paths against the current drive. Durable firstmate records written by
#      the bash twins carry MSYS form (/f/Plotex_projects/...), and both worlds
#      read the same records during the transition, so EVERY path that reaches
#      a .NET or provider API must pass through ConvertTo-FmNativePath first.
#      That conversion is centralized here precisely so no converted script has
#      to remember it.
#
#   3. EXIT CODES ARE PART OF THE INTERFACE.
#      Distinct non-zero codes are load-bearing across this repo (2 = usage or
#      guard deny, 8 = the X-mode retryable hold, and so on), and the
#      differential harness compares them exactly. $ErrorActionPreference must
#      be Stop so a failure never silently continues, but a raw terminating
#      exception must never be what picks the process code - Exit-FmScript is
#      the single sanctioned exit, and Invoke-FmMain wraps a script body so an
#      unexpected exception becomes a declared code plus a diagnostic instead
#      of PowerShell's own.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- console encoding --------------------------------------------------------

# Applied at import, process-wide, because a converted script's stdout is read
# by bash twins, by the differential harness, and by the harness adapters that
# parse firstmate's output. See contract 1 above for why this is not optional.
# Wrapped in try/catch because a redirected or closed console (a hook running
# with no attached terminal) can refuse the assignment, and failing to set a
# console property must never abort a script that only wanted to write a file.
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8NoBom
    [Console]::InputEncoding = $utf8NoBom
    $global:OutputEncoding = $utf8NoBom
} catch {
    # Non-fatal by design: a redirected or closed console (a hook with no
    # attached terminal) refuses these assignments, and failing to set a
    # console property must never abort a script that only wanted to write a
    # file. File writes below carry their own explicit encoding regardless.
    $null = $_
}

# --- reporters ---------------------------------------------------------------

<#
.SYNOPSIS
Write one LF-terminated line to stdout, byte-exactly.
.DESCRIPTION
The sanctioned replacement for `echo`/`printf '%s\n'`. Uses the raw console
writer rather than Write-Output so no CRLF translation, object formatting, or
trailing-newline guesswork can touch the bytes (contract 1).
#>
function Write-FmOut {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Text = '')
    process { [Console]::Out.Write($Text + "`n") }
}

<#
.SYNOPSIS
Write raw text to stdout with no added newline.
.DESCRIPTION
The `printf '%s'` twin, for callers composing partial output or emitting a
record that already carries its own terminator.
#>
function Write-FmRaw {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Text = '')
    process { [Console]::Out.Write($Text) }
}

<#
.SYNOPSIS
Write one LF-terminated line to stderr, byte-exactly.
#>
function Write-FmErr {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Text = '')
    process { [Console]::Error.Write($Text + "`n") }
}

<#
.SYNOPSIS
Write a "<script>: <message>" diagnostic to stderr.
.DESCRIPTION
The twin of the `say()`/`log()` helpers the bash entrypoints define. Prefix
defaults to the calling script's leaf name so messages stay attributable
exactly as the bash originals are ("fm-teardown.sh: ...").
#>
function Write-FmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [string]$Prefix
    )
    if (-not $PSBoundParameters.ContainsKey('Prefix') -or [string]::IsNullOrEmpty($Prefix)) {
        $Prefix = Get-FmScriptName
    }
    Write-FmErr "${Prefix}: $Message"
}

<#
.SYNOPSIS
The leaf name of the running script, for diagnostics.
.DESCRIPTION
Falls back to 'firstmate' when there is no script context (dot-sourced in an
interactive session, or invoked through -Command), so a reporter can never
throw for want of a name.
#>
function Get-FmScriptName {
    [CmdletBinding()]
    param()
    $path = $null
    try { $path = $MyInvocation.PSCommandPath } catch { $path = $null }
    if ([string]::IsNullOrEmpty($path)) {
        try { $path = $global:PSCommandPath } catch { $path = $null }
    }
    if ([string]::IsNullOrEmpty($path)) { return 'firstmate' }
    return [System.IO.Path]::GetFileName($path)
}

# --- exit discipline ---------------------------------------------------------

<#
.SYNOPSIS
The single sanctioned exit path for a firstmate PowerShell entrypoint.
.DESCRIPTION
Flushes both console streams before exiting: a buffered final line lost to an
abrupt exit would read to the differential harness as a stdout mismatch, and to
a harness adapter as a missing verdict. See contract 3.
#>
function Exit-FmScript {
    [CmdletBinding()]
    param([Parameter(Position = 0)][int]$Code = 0)
    # A closed or redirected stream cannot be flushed; exiting is still correct.
    try { [Console]::Out.Flush(); [Console]::Error.Flush() } catch { $null = $_ }
    exit $Code
}

<#
.SYNOPSIS
Run an entrypoint body so no unexpected exception picks the process exit code.
.DESCRIPTION
PowerShell's default for an unhandled terminating error is exit 1 plus a
multi-line formatted error record on stderr - shapes that no bash twin
produces, and that would make every such failure look like a legitimate
"exit 1" outcome to a caller. This wrapper converts an escaped exception into
the caller's declared UnexpectedCode plus a single-line diagnostic, so a real
defect is loud and distinguishable from a script's own documented failures.
#>
function Invoke-FmMain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$Body,
        [int]$UnexpectedCode = 70
    )
    try {
        & $Body
        Exit-FmScript 0
    } catch [System.Management.Automation.ExitException] {
        throw
    } catch {
        Write-FmLog "unexpected failure: $($_.Exception.Message)"
        if ($null -ne $_.ScriptStackTrace) {
            foreach ($line in ($_.ScriptStackTrace -split "`r?`n")) {
                if ($line) { Write-FmErr "  $line" }
            }
        }
        Exit-FmScript $UnexpectedCode
    }
}

# --- path conversion ---------------------------------------------------------

# Resolved once per process: cygpath is a child process, and at ~360ms per
# spawn on a Defender-protected Windows host, calling it per path would be a
# measurable cost in any loop. The pure-string conversions below handle every
# form firstmate actually stores, and cygpath is only consulted for the exotic
# remainder (see ConvertTo-FmNativePath).
$script:FmCygpath = $null
$script:FmCygpathResolved = $false

function Get-FmCygpath {
    if (-not $script:FmCygpathResolved) {
        $script:FmCygpathResolved = $true
        $cmd = Get-Command 'cygpath' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $script:FmCygpath = $cmd.Source }
    }
    return $script:FmCygpath
}

<#
.SYNOPSIS
Convert a path to native Windows form for .NET and provider APIs.
.DESCRIPTION
Handles the forms firstmate durably stores, in order:
  /f/x/y      -> F:\x\y      (MSYS drive form, what the bash twins write)
  /c/Users/x  -> C:\Users\x
  F:/x/y      -> F:\x\y      (mixed separators)
  F:\x\y      -> unchanged
  /tmp/x      -> the MSYS root's tmp, resolved through cygpath when available
Anything already native, UNC, or relative is returned untouched.

The MSYS-drive rule is a pure string transform rather than a cygpath call
because it is exact and hot: a single-letter segment at the root is
unambiguous in this repo's paths. Non-drive absolute POSIX paths (/tmp, /usr)
genuinely need the MSYS mount table, so those consult cygpath, and when cygpath
is unavailable the input is returned unchanged rather than guessed at - a
wrong path is worse than an unconverted one, because the caller's own error
will name the real path.
#>
function ConvertTo-FmNativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    # Already native (drive-letter or UNC): only normalize separators.
    if ($Path -match '^[A-Za-z]:[\\/]') { return $Path -replace '/', '\' }
    if ($Path.StartsWith('\\')) { return $Path }

    # MSYS drive form: /f/... or /F/...
    if ($Path -match '^/([A-Za-z])(/|$)') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = $Path.Substring(2)
        $rest = $rest -replace '/', '\'
        return "${drive}:$rest"
    }

    # Other absolute POSIX paths need the MSYS mount table.
    if ($Path.StartsWith('/')) {
        $cygpath = Get-FmCygpath
        if ($cygpath) {
            try {
                $converted = & $cygpath -w $Path 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($converted)) {
                    return ($converted | Select-Object -First 1).Trim()
                }
            } catch {
                # cygpath failed or is unusable: fall through to returning the
                # input unchanged, because a WRONG path is worse than an
                # unconverted one - the caller's own error names the real path.
                $null = $_
            }
        }
        return $Path
    }

    # Relative: leave as-is; the caller's own cwd decides.
    return $Path
}

<#
.SYNOPSIS
Convert a path to MSYS/POSIX form for durable records and bash interop.
.DESCRIPTION
The inverse of ConvertTo-FmNativePath. Durable firstmate records (state/*.meta
worktree= and window= fields, registry entries) are written in POSIX form while
the bash twins still read them, so a PowerShell script that RECORDS a path
converts on the way out. Contract 3 in docs/powershell-port.md owns when the
stored convention may flip repo-wide.
#>
function ConvertTo-FmPosixPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path.StartsWith('/')) { return $Path }

    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    if ($Path -match '^([A-Za-z]):$') {
        return '/' + $Matches[1].ToLowerInvariant()
    }
    return ($Path -replace '\\', '/')
}

<#
.SYNOPSIS
True when two paths name the same location regardless of path form.
.DESCRIPTION
Comparisons across the bash/PowerShell boundary constantly hit /f/x vs F:\x for
one location. Both sides are normalized to native form, trailing separators
dropped, and compared case-insensitively because Windows filesystems are.
#>
function Test-FmSamePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Right
    )
    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) {
        return $Left -eq $Right
    }
    $l = (ConvertTo-FmNativePath $Left).TrimEnd('\', '/')
    $r = (ConvertTo-FmNativePath $Right).TrimEnd('\', '/')
    return $l.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)
}

# --- bash-compatible environment semantics -----------------------------------

<#
.SYNOPSIS
Read an environment variable with bash `${VAR:-default}` semantics.
.DESCRIPTION
The distinction is load-bearing and easy to get wrong: bash's `:-` treats an
EMPTY value as absent, while `-` treats only an unset value as absent. The
firstmate tree uses `:-` almost everywhere (including the home/state resolution
below), and several tests deliberately export an empty value to prove the
fallthrough - so the default here is the `:-` form, with -EmptyIsValue for the
rarer `${VAR-default}` sites.
#>
function Get-FmEnv {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][AllowEmptyString()][string]$Default = '',
        [switch]$EmptyIsValue
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return $Default }
    if (-not $EmptyIsValue -and $value -eq '') { return $Default }
    return $value
}

# --- home / state resolution -------------------------------------------------

<#
.SYNOPSIS
Resolve the firstmate root, home, and per-home directories.
.DESCRIPTION
The exact twin of the resolution block every bash entrypoint opens with:

    FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
    DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
    CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
    PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

Two subtleties preserved deliberately:
  - FM_HOME wins over FM_ROOT_OVERRIDE, but FM_ROOT_OVERRIDE wins over the
    script-derived root. That ordering is what lets the test suite point a run
    at a scratch home while still overriding where scripts are read from.
  - Every override honors `:-` semantics (empty means absent).

-ScriptRoot is the calling script's own directory ($PSScriptRoot), which stands
in for bash's SCRIPT_DIR; the root is its parent. Returned paths are NATIVE
form, ready for .NET APIs, with PosixHome/PosixRoot alongside for records and
messages that must match what the bash twins write.
#>
function Get-FmContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][string]$ScriptRoot)

    if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = $PSScriptRoot }
    if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
    $ScriptRoot = ConvertTo-FmNativePath $ScriptRoot

    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $derivedRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot '..'))

    $root = if ($rootOverride) { ConvertTo-FmNativePath $rootOverride } else { $derivedRoot }

    # Named fmHome, not home: $HOME is a PowerShell automatic variable, and
    # shadowing it in a module that every script imports invites confusing
    # action-at-a-distance (and a PSScriptAnalyzer violation).
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) {
        ConvertTo-FmNativePath $homeEnv
    } elseif ($rootOverride) {
        ConvertTo-FmNativePath $rootOverride
    } else {
        $root
    }

    $stateOverride = Get-FmEnv 'FM_STATE_OVERRIDE'
    $dataOverride = Get-FmEnv 'FM_DATA_OVERRIDE'
    $configOverride = Get-FmEnv 'FM_CONFIG_OVERRIDE'
    $projectsOverride = Get-FmEnv 'FM_PROJECTS_OVERRIDE'

    return @{
        ScriptRoot = $ScriptRoot
        Root       = $root
        Home       = $fmHome
        State      = if ($stateOverride) { ConvertTo-FmNativePath $stateOverride } else { Join-Path $fmHome 'state' }
        Data       = if ($dataOverride) { ConvertTo-FmNativePath $dataOverride } else { Join-Path $fmHome 'data' }
        Config     = if ($configOverride) { ConvertTo-FmNativePath $configOverride } else { Join-Path $fmHome 'config' }
        Projects   = if ($projectsOverride) { ConvertTo-FmNativePath $projectsOverride } else { Join-Path $fmHome 'projects' }
        PosixRoot  = ConvertTo-FmPosixPath $root
        PosixHome  = ConvertTo-FmPosixPath $fmHome
    }
}

# --- file primitives ---------------------------------------------------------

<#
.SYNOPSIS
Read a file's full text, or '' when it does not exist.
.DESCRIPTION
Mirrors `cat "$f" 2>/dev/null || true`: a missing file is an empty result, not
an error, because the bash tree treats absence as a normal state everywhere.
#>
function Get-FmFileText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    try { return [System.IO.File]::ReadAllText($native) } catch { return '' }
}

<#
.SYNOPSIS
Read a file as an array of lines with no trailing-empty artifact.
.DESCRIPTION
Splits on LF after stripping CR, so a file written by a bash twin, by a
Windows tool that emitted CRLF, or by this module reads identically. A missing
file yields an empty array, matching `while read < missing` doing nothing.
#>
function Get-FmFileLines {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is deliberate and matches the return shape: this yields ALL lines of the file as an array, and the singular form would read as get-one-line. Get-FmFileText is the singular-valued sibling.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $text = Get-FmFileText $Path
    # `,` is load-bearing: a bare `return @()` unrolls on the way out, so an
    # empty result reaches the caller as $null and .Count throws under strict
    # mode, while a one-element result arrives as the bare element.
    if ($text -eq '') { return , @() }
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $text -split "`n"
    if ($lines.Length -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Length - 2)]
    }
    return , @($lines)
}

<#
.SYNOPSIS
Write text to a file with LF endings and UTF-8 (no BOM).
.DESCRIPTION
The `printf '%s\n' > file` twin. -NoNewline suppresses the added terminator for
callers writing an exact byte sequence. CRLF in the supplied text is normalized
so a caller that composed a string from mixed sources cannot leak \r into a
durable record (contract 1).
#>
function Set-FmFileText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are internal helpers on the hot path of scripts whose bash twins write unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive hook.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][AllowEmptyString()][string]$Text = '',
        [switch]$NoNewline
    )
    $native = ConvertTo-FmNativePath $Path
    $body = $Text -replace "`r`n", "`n"
    if (-not $NoNewline -and -not $body.EndsWith("`n")) { $body += "`n" }
    [System.IO.File]::WriteAllText($native, $body, [System.Text.UTF8Encoding]::new($false))
}

<#
.SYNOPSIS
Append one LF-terminated line to a file, creating it when absent.
.DESCRIPTION
The `printf '%s\n' >> file` twin, used for append-only records such as
state/<id>.status and the wake queue.
#>
function Add-FmFileLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Line
    )
    $native = ConvertTo-FmNativePath $Path
    $body = ($Line -replace "`r`n", "`n" -replace "`r", '') + "`n"
    [System.IO.File]::AppendAllText($native, $body, [System.Text.UTF8Encoding]::new($false))
}

<#
.SYNOPSIS
Publish file content atomically: write a sibling temp, then rename over.
.DESCRIPTION
The twin of the repo's pervasive `tmp=$(mktemp "$dir/.x.XXXXXX"); ... ; mv -f`
pattern, which exists so a concurrent reader never observes a half-written
durable record. The temp is created in the DESTINATION directory so the rename
stays same-volume and therefore atomic.

Windows caveat this deliberately surfaces: unlike POSIX rename, a Windows
replace can fail when another process holds the destination open. That is
reported as a failure (returns $false) rather than retried silently, because
the bash twins' callers already treat a failed publish as "leave the old record
in place and try again later" - the safe direction.
#>
function Set-FmFileTextAtomic {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are internal helpers on the hot path of scripts whose bash twins write unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][AllowEmptyString()][string]$Text = '',
        [switch]$NoNewline
    )
    $native = ConvertTo-FmNativePath $Path
    $dir = [System.IO.Path]::GetDirectoryName($native)
    $leaf = [System.IO.Path]::GetFileName($native)
    if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
    $temp = Join-Path $dir (".{0}.fm-tmp.{1}" -f $leaf, ([System.IO.Path]::GetRandomFileName()))
    try {
        Set-FmFileText -Path $temp -Text $Text -NoNewline:$NoNewline
        # Move with overwrite=$true for BOTH cases, rather than Replace for the
        # existing-destination case.
        #
        # [System.IO.File]::Replace($temp, $native, $null) looks right and is
        # not: PowerShell binds that $null third argument as the empty STRING,
        # which is not a valid backup path, so Replace throws and this helper
        # returned $false. It failed only when the destination already existed -
        # i.e. only on the SECOND and later write to a path - which is exactly
        # the shape a fresh-fixture test cannot see, and it failed SILENTLY
        # because the caller gets $false rather than an exception. Found live
        # when every phase transition in fm-pending-reply-lib turned out to be
        # inert: the record was written once and never updated again.
        #
        # The two-argument Move overload (.NET Core 3.0+, so always present
        # under PowerShell 7) performs the same same-volume atomic rename and
        # needs no backup file at all.
        [System.IO.File]::Move($temp, $native, $true)
        return $true
    } catch {
        # Best-effort temp removal; the publish already failed, and failing to
        # clean up must not mask that with a different error.
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
        return $false
    }
}

<#
.SYNOPSIS
True when the path is a symlink or a directory junction.
.DESCRIPTION
The `[ -L "$p" ]` twin. Junctions matter as much as symlinks here: stock Git
Bash cannot create file symlinks without Developer Mode, so the Windows tree
uses junctions for directory links (see bin/fm-windows-setup.sh), and MSYS
itself reports a junction as a symlink. Both are reparse points, which is what
this actually tests.
#>
function Test-FmSymlink {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}

# --- meta records ------------------------------------------------------------

<#
.SYNOPSIS
Read one key from a state/<id>.meta record.
.DESCRIPTION
Byte-compatible with bin/fm-backend.sh's fm_meta_get:

    grep "^$key=" "$meta" | tail -1 | cut -d= -f2-

which means, precisely: the LAST matching line wins (later writes append and
supersede), the value is everything after the FIRST '=' (so a value may itself
contain '='), and a missing file yields an empty string with no error. All
three behaviors are relied on by callers and are reproduced exactly here.
#>
function Get-FmMetaValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    $prefix = "$Key="
    $value = ''
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        if ($line.StartsWith($prefix)) { $value = $line.Substring($prefix.Length) }
    }
    return $value
}

<#
.SYNOPSIS
Read a whole meta record as an ordered dictionary.
.DESCRIPTION
Same last-wins rule as Get-FmMetaValue. Lines without '=' are skipped rather
than throwing, because a truncated record (a crash mid-write) must degrade to
"the keys I can read" exactly as the grep-based bash reader does.
#>
function Get-FmMeta {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory, Position = 0)][string]$MetaPath)
    $meta = [ordered]@{}
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $meta[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
    }
    return $meta
}

<#
.SYNOPSIS
Write a meta record atomically from an ordered dictionary.
.DESCRIPTION
Emits `key=value` lines in insertion order with LF endings, matching what the
bash writers produce, so a record round-trips between the two worlds unchanged.
#>
function Set-FmMeta {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are internal helpers on the hot path of scripts whose bash twins write unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Meta
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($key in $Meta.Keys) {
        [void]$sb.Append($key).Append('=').Append([string]$Meta[$key]).Append("`n")
    }
    return Set-FmFileTextAtomic -Path $MetaPath -Text $sb.ToString() -NoNewline
}

# --- external processes ------------------------------------------------------

<#
.SYNOPSIS
Run an external program, capturing stdout, stderr, and exit code separately.
.DESCRIPTION
The `out=$(cmd 2>/dev/null); rc=$?` twin, but honest about all three channels.
PowerShell's own `&` operator merges native stderr into the output stream under
redirection, which would corrupt any caller that parses stdout - so this uses
System.Diagnostics.Process with both streams redirected and read concurrently
(reading them serially can deadlock when a child fills the other pipe's buffer).

Returns a hashtable: ExitCode, StdOut, StdErr, and Ok (ExitCode -eq 0).
Output has CR stripped so a native Windows tool that emits CRLF - jq being the
motivating example from the Windows bash port - cannot leak \r into parsed
fields. Set -KeepCarriageReturns when a caller genuinely needs raw bytes.

-TimeoutSeconds bounds a hung child: on expiry the process tree is killed and
ExitCode is 124, matching the `timeout` exit convention the bash tree already
tests against.
#>
function Invoke-FmTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FilePath,
        [Parameter(Position = 1)][string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [string]$StdIn,
        [int]$TimeoutSeconds = 0,
        [switch]$KeepCarriageReturns
    )

    # Resolve the command OURSELVES rather than letting .NET search PATH.
    #
    # .NET's process launcher resolves only .exe (and a bare exact name). It
    # does NOT honor PATHEXT the way cmd.exe and a shell do, so a `.cmd`,
    # `.bat` or extension-less script sitting earlier on PATH is INVISIBLE to
    # it - and it silently keeps searching until it finds a real .exe further
    # along. That failure mode is worse than an error: a test that prepends a
    # FAKE tool to PATH gets the REAL tool instead, runs green against
    # production software, and reports that the fake was never called. It cost
    # this port 106 failing assertions in the herdr suite, all with the same
    # misleading signature.
    #
    # Get-Command -CommandType Application applies the platform's real
    # resolution rules, including PATHEXT. A resolved .cmd/.bat cannot be
    # started directly by .NET either, so it goes through cmd.exe /c.
    $resolvedPath = $FilePath
    $cmdShim = $false
    if (-not [System.IO.Path]::IsPathRooted($FilePath)) {
        $found = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $resolvedPath = $found.Source }
    }
    if ($resolvedPath -match '\.(cmd|bat)$') { $cmdShim = $true }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($cmdShim) {
        $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
        $psi.ArgumentList.Add('/c')
        $psi.ArgumentList.Add($resolvedPath)
    } else {
        $psi.FileName = $resolvedPath
    }
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = [bool]$PSBoundParameters.ContainsKey('StdIn')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($PSBoundParameters.ContainsKey('WorkingDirectory') -and $WorkingDirectory) {
        $psi.WorkingDirectory = ConvertTo-FmNativePath $WorkingDirectory
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $stdOut = ''
    $stdErr = ''
    $exitCode = -1
    try {
        [void]$proc.Start()
        # Both pipes are drained concurrently: reading one to completion first
        # deadlocks whenever the child fills the other pipe's buffer.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if ($psi.RedirectStandardInput) {
            $proc.StandardInput.Write($StdIn)
            $proc.StandardInput.Close()
        }
        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                # The child may have exited between the timeout and the kill.
                try { $proc.Kill($true) } catch { $null = $_ }
                $stdOut = ''
                $stdErr = 'fm: timed out'
                return @{ ExitCode = 124; StdOut = $stdOut; StdErr = $stdErr; Ok = $false }
            }
        } else {
            $proc.WaitForExit()
        }
        $stdOut = $outTask.GetAwaiter().GetResult()
        $stdErr = $errTask.GetAwaiter().GetResult()
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    if (-not $KeepCarriageReturns) {
        $stdOut = $stdOut -replace "`r", ''
        $stdErr = $stdErr -replace "`r", ''
    }
    return @{ ExitCode = $exitCode; StdOut = $stdOut; StdErr = $stdErr; Ok = ($exitCode -eq 0) }
}

# Git Bash is located from the well-known install layout rather than PATH: a
# firstmate PowerShell script may run from a harness, a hook, or a herdr pane
# whose PATH carries no POSIX shell even when one is installed. FM_BASH is the
# operator override; a bare "bash" is the last resort so a machine that does
# have it on PATH still works. Resolved once per process.
$script:FmBash = $null
$script:FmBashResolved = $false

function Get-FmBash {
    if (-not $script:FmBashResolved) {
        $script:FmBashResolved = $true
        $candidates = @(
            [Environment]::GetEnvironmentVariable('FM_BASH')
            'C:\Program Files\Git\bin\bash.exe'
            'C:\Program Files\Git\usr\bin\bash.exe'
            'C:\Program Files (x86)\Git\bin\bash.exe'
        ) | Where-Object { $_ }
        foreach ($candidate in $candidates) {
            if ([System.IO.File]::Exists($candidate)) { $script:FmBash = $candidate; break }
        }
        if (-not $script:FmBash) {
            $cmd = Get-Command 'bash' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd) { $script:FmBash = $cmd.Source }
        }
    }
    return $script:FmBash
}

<#
.SYNOPSIS
Invoke a sibling firstmate script, preferring its PowerShell twin.
.DESCRIPTION
THE transition-safe way for one firstmate script to call another. Both trees
coexist for the whole conversion, and the repo has ~157 of these call sites, so
without a single owner every author must guess: hard-coding `.ps1` breaks until
that sibling lands (which would re-serialize the conversion waves and destroy
the parallelism the execute-edge analysis buys), and hard-coding `.sh` leaves
157 sites to sweep at cutover.

This resolves `bin/<Name>.ps1` when it exists and is non-empty, and otherwise
runs `bin/<Name>.sh` through Git Bash. So an execute edge is correct no matter
which side of the conversion its target is on, wave ORDER genuinely stops
mattering for execute edges, and cutover becomes deleting one fallback branch
rather than editing every call site.

-Name is the bare script name with no extension ('fm-fleet-sync'). Returns the
same hashtable as Invoke-FmTool. -Stream inherits the console streams instead
of capturing, for a child whose output belongs to the user (a digest, a
report); capture is the default because most call sites parse the result.
#>
function Invoke-FmScript {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string[]]$Arguments = @(),
        [string]$BinDir,
        [string]$WorkingDirectory,
        [string]$StdIn,
        [int]$TimeoutSeconds = 0,
        [switch]$Stream
    )

    if ([string]::IsNullOrEmpty($BinDir)) { $BinDir = $PSScriptRoot }
    $BinDir = ConvertTo-FmNativePath $BinDir

    $psTwin = Join-Path $BinDir "$Name.ps1"
    $shTwin = Join-Path $BinDir "$Name.sh"

    $command = $null
    $prefix = @()
    if ((Test-Path -LiteralPath $psTwin) -and ((Get-Item -LiteralPath $psTwin).Length -gt 0)) {
        $command = (Get-Process -Id $PID).Path   # the running pwsh, so the twin
        if (-not $command) { $command = 'pwsh' } # inherits this exact version
        $prefix = @('-NoProfile', '-File', $psTwin)
    } elseif (Test-Path -LiteralPath $shTwin) {
        $command = Get-FmBash
        if (-not $command) {
            return @{ ExitCode = 127; StdOut = ''; StdErr = "fm: no bash available to run $Name.sh"; Ok = $false }
        }
        # Bash receives a POSIX path: it cannot be relied on to accept a
        # Windows drive path as a script argument.
        $prefix = @((ConvertTo-FmPosixPath $shTwin))
    } else {
        return @{ ExitCode = 127; StdOut = ''; StdErr = "fm: no twin found for $Name"; Ok = $false }
    }

    $argv = @($prefix) + @($Arguments)

    if ($Stream) {
        # Streams belong to the child; only the exit code comes back.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $command
        foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        if ($WorkingDirectory) { $psi.WorkingDirectory = ConvertTo-FmNativePath $WorkingDirectory }
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $proc.WaitForExit()
            return @{ ExitCode = $proc.ExitCode; StdOut = ''; StdErr = ''; Ok = ($proc.ExitCode -eq 0) }
        } finally {
            $proc.Dispose()
        }
    }

    $invokeArgs = @{ FilePath = $command; Arguments = $argv }
    if ($WorkingDirectory) { $invokeArgs['WorkingDirectory'] = $WorkingDirectory }
    if ($PSBoundParameters.ContainsKey('StdIn')) { $invokeArgs['StdIn'] = $StdIn }
    if ($TimeoutSeconds -gt 0) { $invokeArgs['TimeoutSeconds'] = $TimeoutSeconds }
    return Invoke-FmTool @invokeArgs
}

<#
.SYNOPSIS
True when an external command is available on PATH.
.DESCRIPTION
The `command -v x >/dev/null 2>&1` twin. CommandType is pinned to Application
so a PowerShell function or alias of the same name can never masquerade as the
external tool the caller means to run.
#>
function Test-FmCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    return [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
}

# --- platform ----------------------------------------------------------------

<#
.SYNOPSIS
True when running on Windows.
.DESCRIPTION
$IsWindows is an automatic variable in PowerShell 7; this wrapper exists so
converted scripts read like their bash twins' OSTYPE checks and so the check
has one owner if it ever needs to grow.
#>
function Test-FmWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$IsWindows
}

Export-ModuleMember -Function @(
    'Write-FmOut', 'Write-FmRaw', 'Write-FmErr', 'Write-FmLog', 'Get-FmScriptName',
    'Exit-FmScript', 'Invoke-FmMain',
    'ConvertTo-FmNativePath', 'ConvertTo-FmPosixPath', 'Test-FmSamePath',
    'Get-FmEnv', 'Get-FmContext',
    'Get-FmFileText', 'Get-FmFileLines', 'Set-FmFileText', 'Add-FmFileLine',
    'Set-FmFileTextAtomic', 'Test-FmSymlink',
    'Get-FmMetaValue', 'Get-FmMeta', 'Set-FmMeta',
    'Invoke-FmTool', 'Invoke-FmScript', 'Get-FmBash', 'Test-FmCommand', 'Test-FmWindows'
)
