# fm-secondmate-report.ps1 - optional helper to append a correlated parent report.
#
# Twin: bin/fm-secondmate-report.sh
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# Usage:
#   fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh "$STATUS" done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc "$STATUS" done abcdef0123456789 data/x/report.md "see report"
#
# The status file must be the absolute parent route from the secondmate charter
# (state/<id>.status under the PARENT home), never a path relative to this
# secondmate home. Writing under the wrong home is detected as supporting
# evidence by the parent pending-reply guard and does not acknowledge the
# request.
#
# ---------------------------------------------------------------------------
# NOTES ON THE CONVERSION
#
#   NO param() BLOCK, for the same reason as bin/fm-operational-input.ps1: the
#   bash CLI takes bare positional words and one of them is `--doc`. A declared
#   param block makes PowerShell try to BIND `--doc` as a parameter name and
#   fail before the script runs, so every argument must land in $args verbatim.
#
#   ORDER OF THE REFUSALS IS LOAD-BEARING. The bash validates the corr id
#   BEFORE it notices an empty status file, so `'' verb badcorr note` exits 1
#   with the corr diagnostic rather than 2 with usage. Reproduced exactly,
#   because a caller branching on 1 (bad token, retry with the right one) vs 2
#   (wrong invocation) would otherwise read the wrong outcome.
#
#   The corr token is built by Get-FmPendingReplyCorrToken rather than
#   re-spelled here - the parent guard matches on that exact spelling, and two
#   independent spellings of one wire token is precisely how they drift apart.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pending-reply-lib.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    # The `usage()` twin: two lines to stderr, then exit 2.
    $usage = {
        Write-FmErr 'Usage:'
        Write-FmErr '  fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>'
        Write-FmErr '  fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>'
        Exit-FmScript 2
    }

    $argv = @($fmArgv)
    $docMode = $false
    if ($argv.Count -gt 0 -and $argv[0] -ceq '--doc') {
        $docMode = $true
        $argv = @($argv[1..($argv.Count - 1)])
    }

    if ($argv.Count -lt 4) { & $usage }

    $statusFile = [string]$argv[0]
    $verb = [string]$argv[1]
    $corr = [string]$argv[2]
    # `shift 3`.
    $rest = @()
    if ($argv.Count -gt 3) { $rest = @($argv[3..($argv.Count - 1)]) }

    # `case "$CORR" in corr=*) CORR=${CORR#corr=} ;; esac` - accept either the
    # bare id or the wire token the request carried, so a caller can paste the
    # token straight out of the message it is answering.
    if ($corr.StartsWith('corr=')) { $corr = $corr.Substring('corr='.Length) }

    # The bash spells this as a 16-element character-class glob rather than a
    # regex; the class is the same set, and the anchors are implicit in `case`.
    if ($corr -cnotmatch '^[a-fA-F0-9]{16}$') {
        Write-FmErr "error: corr_id must be 16 hex characters (got '$corr')"
        Exit-FmScript 1
    }

    if ($statusFile -eq '') { & $usage }

    # `mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true` followed by an
    # explicit `-d` test: the creation is best-effort and the TEST is the
    # verdict, so a path that could not be created is reported by name rather
    # than as a failed mkdir.
    $statusNative = ConvertTo-FmNativePath $statusFile
    $parent = [System.IO.Path]::GetDirectoryName($statusNative)
    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    try { [void][System.IO.Directory]::CreateDirectory($parent) } catch { $null = $_ }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Write-FmErr "error: cannot create parent directory for status file '$statusFile'"
        Exit-FmScript 1
    }

    $token = Get-FmPendingReplyCorrToken $corr

    if ($docMode) {
        if ($rest.Count -lt 1) { & $usage }
        $docPath = [string]$rest[0]
        # `NOTE=$*` after the shift: the remaining words joined by ONE space,
        # which is what $* does with the default IFS.
        $note = ''
        if ($rest.Count -gt 1) { $note = (@($rest[1..($rest.Count - 1)]) -join ' ') }
        if ($note -ne '') {
            Add-FmFileLine -Path $statusNative -Line "$verb [$token]: $note ($docPath via-helper)"
        } else {
            Add-FmFileLine -Path $statusNative -Line "$verb [$token]: $docPath (via-helper)"
        }
    } else {
        $note = (@($rest) -join ' ')
        if ($note -ne '') {
            Add-FmFileLine -Path $statusNative -Line "$verb [$token]: $note (via-helper)"
        } else {
            Add-FmFileLine -Path $statusNative -Line "$verb [$token]: (via-helper)"
        }
    }

    Exit-FmScript 0
}
