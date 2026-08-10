# bin/fm-project-mode.ps1 - resolve a project's delivery mode and yolo flag from
# the data/projects.md registry.
#
# Twin: bin/fm-project-mode.sh
#
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and
# warns to stderr, so a typo never silently drops the gate.
#
# ---------------------------------------------------------------------------
# WHY THE PARSE IS SPELLED OUT RATHER THAN REGEXED
#
# The bash twin delegates to awk, and this file reproduces awk's semantics
# rather than a plausible-looking regex, because two of them decide real
# authority:
#
#   1. FIELDS ARE AWK FIELDS. `$1=="-" && $2==n` splits on RUNS of whitespace
#      with leading whitespace ignored, so an indented registry line matches and
#      a name is compared as a whole field - never as a substring. A regex over
#      the raw line would either miss the indented form or match a name that is
#      merely a prefix of another, and both mistakes silently hand a project the
#      wrong delivery mode.
#
#   2. AN UNCLOSED BRACKET IS NOT AN ERROR. awk accumulates fields from $3 until
#      one ENDS with ']', or until the end of the line if none does; the
#      `gsub(/^\[|\]$/, "")` that follows strips whatever brackets are actually
#      there. So `- p [direct-PR - desc` still yields direct-PR. That is not
#      obviously desirable, but it is what the bash owner does today, and a twin
#      that "fixed" it would change a live project's merge path.
#
# The two-word result is then re-split by the bash twin with `${parsed%% *}` /
# `${parsed##* }` before validation; that round trip is inlined here because
# neither field can contain a space (both come from awk fields).
#
# ---------------------------------------------------------------------------
# PATHS ARE COMPOSED AS STRINGS, NOT THROUGH Get-FmContext
#
# Get-FmContext returns NATIVE paths, which is right for file APIs and wrong
# here: the "no registry at <path>" warning prints the composed path, and the
# differential harness compares that line against the bash twin's byte for byte.
# So the registry path is built by the same string concatenation bash performs
# (POSIX form in, POSIX form out) and converted to native form only at the
# moment it reaches a .NET file API.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCE FROM THE BASH ORACLE
#
#   MISSING ARGUMENT. bash's `${1:?usage: ...}` aborts the shell with its own
#   "<script>: line 29: 1: " prefix before the usage text, and that prefix
#   embeds a line number no twin should pin. Here the exit code (1) and the
#   trailing usage text are identical; the bash prefix is not reproduced. The
#   differential suite compares the code and the usage suffix rather than the
#   whole line.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    # `if [ "${1:-}" = "--raw" ]; then RAW=1; shift; fi` - an EXACT first-argument
    # match, not a general flag parser: a later --raw is a project name, and so
    # is a second one, exactly as the bash reads them.
    $argv = @($fmArgv)
    $raw = $false
    if ($argv.Count -ge 1 -and ([string]$argv[0]) -ceq '--raw') {
        $raw = $true
        # Plain if/else STATEMENTS, not `$x = if (...) {...}`: an if used as an
        # expression writes through the output stream, which unrolls a
        # one-element array to the bare element and an empty one to $null - so
        # the .Count read below would fail even with @() around the slice.
        # Assigning inside each branch keeps the array intact.
        if ($argv.Count -gt 1) { $argv = @($argv[1..($argv.Count - 1)]) } else { $argv = @() }
    }
    $name = if ($argv.Count -ge 1) { [string]$argv[0] } else { '' }
    if ([string]::IsNullOrEmpty($name)) {
        Write-FmErr 'usage: fm-project-mode.sh [--raw] <project-name>'
        Exit-FmScript 1
    }

    # The bash resolution block, verbatim in string terms:
    #   FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    #   FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    #   DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
    }
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }
    $data = Get-FmEnv 'FM_DATA_OVERRIDE' "$fmHome/data"
    $registry = "$data/projects.md"

    $registryNative = ConvertTo-FmNativePath $registry
    if (-not [System.IO.File]::Exists($registryNative)) {
        Write-FmErr "warn: no registry at $registry; defaulting $name to no-mistakes off"
        Write-FmOut 'no-mistakes off'
        Exit-FmScript 0
    }

    # awk emits "<mode> <yolo>" for the FIRST matching line, or nothing.
    $mode = $null
    $yolo = $null
    foreach ($line in (Get-FmFileLines $registry)) {
        # awk field splitting: leading/trailing whitespace ignored, runs collapse.
        $fields = @($line -split '\s+' | Where-Object { $_ -ne '' })
        if ($fields.Count -lt 2) { continue }
        if ($fields[0] -cne '-') { continue }
        if ($fields[1] -cne $name) { continue }

        $mode = 'no-mistakes'
        $yolo = 'off'
        if ($fields.Count -ge 3 -and $fields[2].StartsWith('[', [System.StringComparison]::Ordinal)) {
            $bracket = ''
            for ($i = 2; $i -lt $fields.Count; $i++) {
                if ($bracket -ne '') { $bracket += ' ' }
                $bracket += $fields[$i]
                if ($fields[$i].EndsWith(']', [System.StringComparison]::Ordinal)) { break }
            }
            # gsub(/^\[|\]$/, "", s): a leading '[' and a trailing ']', each only
            # if present. "[]" collapses to the empty string, which is why the
            # a[1] emptiness test below is not dead code.
            if ($bracket.StartsWith('[', [System.StringComparison]::Ordinal)) {
                $bracket = $bracket.Substring(1)
            }
            if ($bracket.EndsWith(']', [System.StringComparison]::Ordinal)) {
                $bracket = $bracket.Substring(0, $bracket.Length - 1)
            }
            $tokens = @($bracket -split '\s+' | Where-Object { $_ -ne '' })
            if ($tokens.Count -ge 1 -and $tokens[0] -cne '+yolo') { $mode = $tokens[0] }
            foreach ($token in $tokens) { if ($token -ceq '+yolo') { $yolo = 'on' } }
        }
        break
    }

    if ($null -eq $mode) {
        Write-FmErr "warn: project `"$name`" not in registry; defaulting to no-mistakes off"
        Write-FmOut 'no-mistakes off'
        Exit-FmScript 0
    }

    if ($mode -cne 'no-mistakes' -and $mode -cne 'direct-PR' -and
        $mode -cne 'local-only' -and $mode -cne 'no-mistakes-prod-only') {
        Write-FmErr "warn: unknown mode `"$mode`" for $name; defaulting to no-mistakes off"
        $mode = 'no-mistakes'
        $yolo = 'off'
    }
    if ($yolo -cne 'on' -and $yolo -cne 'off') { $yolo = 'off' }
    # A conditional policy is not a task mode. Mechanical callers get its most
    # rigorous leg; --raw callers get the annotation itself, so a caller that
    # must tell a conditional policy apart from a flat mode can.
    if ((-not $raw) -and $mode -ceq 'no-mistakes-prod-only') { $mode = 'no-mistakes' }

    Write-FmOut "$mode $yolo"
    Exit-FmScript 0
}
