# bin/fm-arm-pretool-check.ps1 - stable PreToolUse transport for the watcher-arm
# command policy.
#
# Twin: bin/fm-arm-pretool-check.sh
#
# A firstmate primary must arm the watcher or run a Codex checkpoint as a
# standalone verified harness call.
# bin/fm-arm-command-policy.mjs is the sole owner of shell classification,
# protected execution identity, the blessed setup tree, and deny reason codes.
# This wrapper only acquires the harness payload, discovers the active roots,
# invokes that policy, and renders the established harness-specific responses.
# It never executes, sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | pwsh -NoProfile -File bin/fm-arm-pretool-check.ps1
#   pwsh -NoProfile -File bin/fm-arm-pretool-check.ps1 --command '<cmd>' [--background true|false]
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex.
# CLI mode is used by OpenCode and Pi after their adapters extract the exact
# command string.
# --background remains accepted for compatibility, but harness-native tracked
# background execution is not itself a policy signal.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, missing Node or policy owner, or an
#               invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
#
# ---------------------------------------------------------------------------
# SIX MECHANICS THAT DECIDE WHETHER THIS TWIN IS FAITHFUL
#
#   1. NO param() BLOCK, for the same reason bin/fm-operational-input.ps1 has
#      none: this CLI takes bare positional words and one of them is `-h`. A
#      declared param block makes PowerShell try to BIND `-h` and fail before
#      the script body runs, so every adapter that passes the bash argv through
#      unchanged would get a binding error instead of usage.
#
#   2. FAIL OPEN IS THE WHOLE POINT, AND IT IS SILENT. Every uncertainty in the
#      bash twin is `|| exit 0` with stderr redirected away, so a broken
#      environment never blocks the captain's shell. The catch-all at the
#      bottom therefore exits 0 with NO diagnostic - deliberately not
#      Invoke-FmMain, whose declared-code-plus-stderr-trace behavior is right
#      for a data CLI and wrong for a guard that must disappear when it breaks.
#      The body returns an exit code rather than calling exit, so there is
#      exactly one exit point and no `exit` can slip past the catch.
#
#   3. jq IS NOT A DEPENDENCY HERE, AND THAT IS A DELIBERATE DIVERGENCE. The
#      bash twin fails open when jq is missing, because jq is its only JSON
#      reader. PowerShell parses JSON in-process (docs/powershell-port.md), so
#      this twin has nothing to be missing: on a host without jq it still
#      classifies, where bash allows. The divergence is strictly in the
#      guarding direction, is asserted explicitly by
#      tests/fm-hooks-psm1.test.sh rather than normalized away, and disappears
#      at cutover when the bash transport retires.
#
#   4. --root AND --home GO TO NODE IN POSIX FORM. The policy owner compares
#      them with path.normalize/path.join against words taken from the command
#      text, and it touches the filesystem with neither. The bash twin hands it
#      MSYS form (/f/...), so a command naming /f/<root>/bin/fm-watch.sh
#      matches. Handing native form (F:\...) instead would normalize to a
#      different string and silently stop matching exactly the protected paths
#      this guard exists for - contract 3 in docs/powershell-port.md, here with
#      teeth.
#
#   5. NO -Force ON THE IMPORT. In a freshly spawned hook process it buys
#      nothing, and it is actively harmful when this entrypoint is driven
#      IN-PROCESS, which is how tests/fm-hooks-psm1.test.sh keeps a whole
#      differential suite to ONE pwsh startup: -Force re-runs fm-common's module
#      body, and its console-encoding assignment RESETS [Console]::In and
#      [Console]::Out, discarding the caller's per-case redirection. The stdin
#      transport then reads the DRIVER's real stdin, and a guard silently
#      classifies the wrong payload. docs/powershell-port.md reserves -Force for
#      a test or tool that deliberately wants a fresh copy of a module under
#      test; an entrypoint is neither.
#
#   6. THE PREFILTER IS A STRICT SUPERSET, NOT AN OPTIMIZATION. Its byte
#      transforms and its quoting-decoder marker set are COUPLED to
#      bin/fm-arm-command-policy.mjs exactly as the bash twin's are; see the
#      comment at the prefilter below, which is carried across verbatim in
#      substance because it is a safety argument, not an explanation.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force: see mechanic 5 in the header.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$fmArgv = @($args)

# The `usage()` heredoc, one array element per line. It still names the .sh
# twin: this text is the documented CLI surface (contract 4), and the two files
# must print the same bytes while both exist.
$script:FmArmUsage = @(
    'Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude]'
    ''
    'With no --command, reads a PreToolUse-style JSON payload on stdin (Grok'
    'toolInput.command, or Claude/Codex tool_input.command).'
    'Exits 0 to allow and 2 to deny.'
    'The deny reason is written to stderr, with a Grok decision object on stdout'
    'unless --claude is supplied.'
    'Malformed transport and an unavailable classifier runtime fail open.'
)

<#
.SYNOPSIS
The json_escape() twin: escape backslashes and quotes, then flatten newlines.
.DESCRIPTION
Byte-exact with `sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '`, including
what it does NOT do: carriage returns and other control bytes pass through
untouched, so a policy reason carrying one produces the same (technically
lax) JSON in both worlds rather than one world quietly emitting stricter JSON
than the other.
#>
function ConvertTo-FmHookJsonText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')
    return $Text.Replace('\', '\\').Replace('"', '\"').Replace("`n", ' ')
}

<#
.SYNOPSIS
Render the two harness-shaped deny objects.
.DESCRIPTION
Claude requires stdout to stay EMPTY on a deny, so the Grok decision object is
suppressed under -ClaudeMode. Both lines are LF-terminated through fm-common's
writers; a CRLF here would corrupt the JSON a harness parses.
#>
function Write-FmHookDeny {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Detail,
        [switch]$ClaudeMode
    )
    $escaped = ConvertTo-FmHookJsonText $Detail
    Write-FmErr ('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"' + $escaped + '"}')
    if (-not $ClaudeMode) {
        Write-FmOut ('{"decision":"deny","reason":"' + $escaped + '"}')
    }
}

<#
.SYNOPSIS
The `jq -r '(.a.b // .c.d // empty)'` twin over an already-parsed payload.
.DESCRIPTION
Walks each candidate path in order and returns the first scalar it finds.
`//` in jq skips null AND false, which is reproduced. Objects and arrays are
skipped rather than re-serialized: no harness sends one here, and a caller that
did would be handing this guard a command it cannot classify anyway.

The trailing-newline trim is not cosmetic - the bash twin captures jq through
`$(...)`, which strips every trailing newline, so a value that ends in one must
compare equal across the two worlds.
#>
function Get-FmHookPayloadField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Payload,
        [Parameter(Mandatory, Position = 1)][string[][]]$Paths
    )

    if ($null -eq $Payload -or -not ($Payload -is [System.Collections.IDictionary])) { return '' }

    foreach ($path in $Paths) {
        $node = $Payload
        $ok = $true
        foreach ($key in $path) {
            if (-not ($node -is [System.Collections.IDictionary]) -or -not $node.Contains($key)) {
                $ok = $false
                break
            }
            $node = $node[$key]
        }
        if (-not $ok) { continue }
        if ($null -eq $node) { continue }
        if ($node -is [System.Collections.IDictionary] -or $node -is [array]) { continue }
        if ($node -is [bool]) {
            if (-not $node) { continue }
            return 'true'
        }
        $value = ([string]$node).TrimEnd("`n")
        if ($value -ne '') { return $value }
    }
    return ''
}

<#
.SYNOPSIS
Read and parse the PreToolUse payload on stdin, or $null when unusable.
.DESCRIPTION
The `PAYLOAD=$(cat) ; jq ... || exit 0` twin. Empty stdin and unparseable JSON
are both "no payload", which every caller turns into a silent allow.
#>
function Read-FmHookPayload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $raw = ''
    try { $raw = [Console]::In.ReadToEnd() } catch { return $null }
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    try {
        $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 64
    } catch {
        return $null
    }
    if ($parsed -is [hashtable]) { return $parsed }
    return $null
}

<#
.SYNOPSIS
The whole transport, returning the process exit code instead of taking it.
.DESCRIPTION
Every `exit 0` in the bash twin is a `return 0` here so the single catch-all at
the bottom of the file cannot be bypassed by an early exit, and so a defect in
one branch cannot leave the guard half-rendered.
#>
function Invoke-FmArmPreToolCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $cmd = ''
    $cmdSet = $false
    $background = ''
    $claudeMode = $false

    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = $Arguments[$i]
        if ($arg -ceq '--command') {
            if ($i + 1 -ge $Arguments.Count) {
                Write-FmErr 'error: --command requires a value'
                return 2
            }
            $cmd = $Arguments[$i + 1]
            $cmdSet = $true
            $i += 2
        } elseif ($arg.StartsWith('--command=')) {
            $cmd = $arg.Substring('--command='.Length)
            $cmdSet = $true
            $i += 1
        } elseif ($arg -ceq '--background') {
            if ($i + 1 -ge $Arguments.Count) {
                Write-FmErr 'error: --background requires a value'
                return 2
            }
            $background = $Arguments[$i + 1]
            $i += 2
        } elseif ($arg.StartsWith('--background=')) {
            $background = $arg.Substring('--background='.Length)
            $i += 1
        } elseif ($arg -ceq '--claude') {
            $claudeMode = $true
            $i += 1
        } elseif ($arg -ceq '-h' -or $arg -ceq '--help') {
            foreach ($line in $script:FmArmUsage) { Write-FmOut $line }
            return 0
        } else {
            Write-FmErr "error: unknown argument: $arg"
            foreach ($line in $script:FmArmUsage) { Write-FmErr $line }
            return 2
        }
    }

    if (-not $cmdSet) {
        $payload = Read-FmHookPayload
        if ($null -eq $payload) { return 0 }
        [string[][]]$commandPaths = @(@('toolInput', 'command'), @('tool_input', 'command'))
        $cmd = Get-FmHookPayloadField $payload $commandPaths
        if ([string]::IsNullOrEmpty($cmd)) { return 0 }
        # Kept for transport parity only, exactly as the bash twin keeps it
        # behind a shellcheck disable: harness-native tracked background
        # execution is not a policy signal.
        [string[][]]$backgroundPaths = @(@('toolInput', 'background'), @('tool_input', 'background'))
        $background = Get-FmHookPayloadField $payload $backgroundPaths
        if ([string]::IsNullOrEmpty($background)) { $background = 'false' }
    }
    $null = $background

    if ([string]::IsNullOrEmpty($cmd)) { return 0 }

    # Strict-superset prefilter (transport only; owns zero classification
    # semantics). Every protected watcher execution and every broad watcher kill
    # resolves to the fm-watch byte sequence AFTER the classifier's byte
    # normalization, so a command that cannot contain fm-watch even after that
    # normalization can never be a deniable watcher command and is fast-allowed
    # without the Node policy owner. We mirror the classifier's cheapest byte
    # transforms here (drop line-continuation and escape backslashes, quotes,
    # and newlines) so obfuscated protected paths such as
    # fm-watc\<newline>h-arm.sh or fm-"watch"-arm.sh still delegate. Stripping
    # only these non-alphanumeric bytes can never destroy an existing fm-watch
    # run.
    #
    # The fast path may allow ONLY when BOTH hold: (a) the stripped/normalized
    # text lacks the fm-watch watcher substring, AND (b) the raw command carries
    # no quoting-decoder marker - a $ immediately followed by a single quote
    # (ANSI-C $'...') or a double quote (bash locale $"..."), both of which the
    # classifier decodes and can therefore reconstruct fm-watch from bytes this
    # cheap byte strip cannot. This marker set is COUPLED to the classifier's
    # decoder set in bin/fm-arm-command-policy.mjs: adding any new
    # quote/expansion form the classifier decodes REQUIRES extending this marker
    # set in the same change, or the prefilter stops being a strict superset.
    # Otherwise the command always delegates to the classifier - the single
    # owner of every decision. Any deeper decode-required obfuscation stays the
    # classifier's and the post-arm liveness guards' responsibility.
    $ansiCMarker = "`$'"
    $localeMarker = '$"'
    if (-not ($cmd.Contains($ansiCMarker) -or $cmd.Contains($localeMarker))) {
        $prefilter = $cmd.Replace('\', '').Replace('"', '').Replace("'", '').Replace("`n", '').Replace("`r", '')
        if (-not $prefilter.Contains('fm-watch')) { return 0 }
    }

    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $activeHome = Get-FmEnv 'FM_HOME' $root
    $policy = Join-Path (Join-Path $root 'bin') 'fm-arm-command-policy.mjs'

    if (-not (Test-FmCommand 'node')) { return 0 }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $policy))) { return 0 }
    $node = Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { return 0 }

    # POSIX form for --root/--home: see mechanic 4 in the header.
    $result = Invoke-FmTool -FilePath $node.Source -Arguments @(
        (ConvertTo-FmNativePath $policy),
        '--command', $cmd,
        '--root', (ConvertTo-FmPosixPath $root),
        '--home', (ConvertTo-FmPosixPath $activeHome)
    )
    if (-not $result.Ok) { return 0 }

    # `$(...)` strips every trailing newline; the field split below depends on
    # that, because a trailing LF would otherwise ride along inside REASON.
    $output = $result.StdOut.TrimEnd("`n")
    if ([string]::IsNullOrEmpty($output)) { return 0 }

    # The bash field split is `%%TAB*` / `#*TAB` with an explicit
    # "did the prefix actually change" test standing in for "was there a
    # separator". Split with a count of 3 says the same thing directly: fewer
    # than three fields means the policy answer is malformed, which fails open.
    $fields = @($output.Split("`t", 3))
    if ($fields.Count -lt 1) { return 0 }
    if ($fields[0] -cne 'deny') { return 0 }
    if ($fields.Count -lt 3) { return 0 }
    $code = $fields[1]
    $reason = $fields[2]
    if ([string]::IsNullOrEmpty($code) -or [string]::IsNullOrEmpty($reason)) { return 0 }

    Write-FmHookDeny -Detail "[$code] $reason" -ClaudeMode:$claudeMode
    return 2
}

$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmArmPreToolCheck -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    # Fail open, silently. See mechanic 2 in the header: a guard that cannot
    # decide must be indistinguishable from a guard that allowed.
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
