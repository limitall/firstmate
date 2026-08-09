# bin/fm-cd-pretool-check.ps1 - stable PreToolUse transport for the cd-guard
# command policy.
#
# Twin: bin/fm-cd-pretool-check.sh
#
# A stray persistent top-level `cd projects/<clone>` in the PRIMARY firstmate
# shell silently relocates the shell, so a later firstmate-owned command (a
# backlog write, an fm-* lifecycle call, tasks-axi) runs inside a project clone
# instead of the home. This seatbelt denies such a command before it runs.
# bin/fm-cd-command-policy.mjs is the sole owner of the block/allow decision; it
# reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only scopes the guard to the real primary checkout, acquires the
# harness payload, invokes that policy, and renders the established harness
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/cd-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | pwsh -NoProfile -File bin/fm-cd-pretool-check.ps1
#   pwsh -NoProfile -File bin/fm-cd-pretool-check.ps1 --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode and Pi after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-arm-pretool-check.ps1):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not the real primary checkout (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing Node or policy owner, or an
#               invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES. bin/fm-arm-pretool-check.ps1's header owns the mechanics
# both transports share (no param() block so `-h` reaches the body, silent
# fail-open through a returned exit code rather than Invoke-FmMain, in-process
# JSON instead of jq, an import without -Force, and a prefilter that is a strict
# superset coupled to the classifier). Two are specific to this file:
#
#   THE SCOPE CHECK IS THE GUARD'S SAFETY, NOT ITS FEATURE. Every one of the
#   five structural checks below fails OPEN. A missing git, an unreadable
#   repo, a linked worktree, a repo that is not firstmate at all - each is
#   exit 0 with no output. That is why this hook can ship enabled by default:
#   the worst a broken environment can do is stop guarding.
#
#   GIT PATHS GO NATIVE, GIT ANSWERS COMPARE RAW. git.exe is called directly
#   here rather than through MSYS, so -C takes the native root. The two
#   rev-parse answers are then compared as RAW STRINGS exactly as bash
#   compares them: git picks one form and uses it for BOTH (relative '.git' in
#   a plain checkout, absolute in a linked worktree), so string equality is the
#   real test, and normalizing them first would only invent ways for the two to
#   look equal when git says they are not.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force: see mechanic 5 in bin/fm-arm-pretool-check.ps1's header.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$fmArgv = @($args)

# The `usage()` heredoc, one array element per line. It still names the .sh
# twin: this text is the documented CLI surface (contract 4), and the two files
# must print the same bytes while both exist.
$script:FmCdUsage = @(
    'Usage: fm-cd-pretool-check.sh [--command <cmd>] [--claude]'
    ''
    'With no --command, reads a PreToolUse-style JSON payload on stdin (Grok'
    'toolInput.command, or Claude/Codex tool_input.command).'
    'Fires only in the real primary firstmate checkout; it is a silent no-op in a'
    'crewmate/scout task worktree or any non-firstmate repo.'
    'Exits 0 to allow and 2 to deny a persistent top-level cwd change.'
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
untouched, so a policy reason carrying one produces the same JSON in both
worlds rather than one world quietly emitting stricter JSON than the other.
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
suppressed under -ClaudeMode.
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
See bin/fm-arm-pretool-check.ps1 for the full reasoning; the trailing-newline
trim reproduces `$(...)`, which strips every trailing newline from jq's output.
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
#>
function Invoke-FmCdPreToolCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $cmd = ''
    $cmdSet = $false
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
        } elseif ($arg -ceq '--claude') {
            $claudeMode = $true
            $i += 1
        } elseif ($arg -ceq '-h' -or $arg -ceq '--help') {
            foreach ($line in $script:FmCdUsage) { Write-FmOut $line }
            return 0
        } else {
            Write-FmErr "error: unknown argument: $arg"
            foreach ($line in $script:FmCdUsage) { Write-FmErr $line }
            return 2
        }
    }

    if (-not $cmdSet) {
        $payload = Read-FmHookPayload
        if ($null -eq $payload) { return 0 }
        [string[][]]$commandPaths = @(@('toolInput', 'command'), @('tool_input', 'command'))
        $cmd = Get-FmHookPayloadField $payload $commandPaths
    }

    if ([string]::IsNullOrEmpty($cmd)) { return 0 }

    # Strict-superset prefilter (transport only; owns zero classification
    # semantics). Strip syntax bytes that the classifier joins within a shell
    # word before looking for cd/pushd/popd, so ordinary quoted or escaped
    # fragments cannot hide a deniable cwd change from the policy owner. A
    # quoting-decoder marker - a $ immediately followed by a single quote
    # (ANSI-C $'...') or a double quote (bash locale $"...") - delegates too,
    # because the classifier decodes those and can reconstruct cd from bytes
    # this substring test cannot see. This marker set is COUPLED to the
    # classifier's decoder set in bin/fm-arm-command-policy.mjs: adding any new
    # quote/expansion form the classifier decodes REQUIRES extending it here in
    # the same change, or the prefilter stops being a strict superset.
    # Deliberate deeper obfuscation is out of scope by the same agent-mistake
    # threat model the policy uses.
    $ansiCMarker = "`$'"
    $localeMarker = '$"'
    if (-not ($cmd.Contains($ansiCMarker) -or $cmd.Contains($localeMarker))) {
        $prefilter = $cmd.Replace('\', '').Replace('"', '').Replace("'", '').Replace("`n", '').Replace("`r", '')
        if (-not ($prefilter.Contains('cd') -or $prefilter.Contains('pushd') -or $prefilter.Contains('popd'))) {
            return 0
        }
    }

    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        ConvertTo-FmNativePath $rootOverride
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }

    # Scope to a plain, non-worktree firstmate checkout, where git-dir equals
    # git-common-dir. A crewmate/scout task worktree - the shape bin/fm-spawn.sh
    # always hands out - is a linked git worktree where the two differ. This
    # guard does not inspect .fm-secondmate-home, so it applies in a git-cloned
    # secondmate home but remains inert when the secondmate home is itself a
    # treehouse-leased linked worktree. docs/cd-guard.md owns this scope;
    # docs/turnend-guard.md owns the turn-end guard's separate marker-aware
    # scope. Any failure to confirm the checkout is inert (exit 0), never a
    # block, so a broken environment never denies a shell command.
    if (-not [System.IO.File]::Exists((Join-Path $fmRoot 'AGENTS.md'))) { return 0 }
    if (-not (Test-Path -LiteralPath (Join-Path $fmRoot 'bin') -PathType Container)) { return 0 }
    if (-not (Test-FmCommand 'git')) { return 0 }
    $gitDir = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $fmRoot, 'rev-parse', '--git-dir')
    if (-not $gitDir.Ok) { return 0 }
    $gitCommonDir = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $fmRoot, 'rev-parse', '--git-common-dir')
    if (-not $gitCommonDir.Ok) { return 0 }
    if ($gitDir.StdOut.TrimEnd("`n") -cne $gitCommonDir.StdOut.TrimEnd("`n")) { return 0 }

    $policy = Join-Path (Join-Path $fmRoot 'bin') 'fm-cd-command-policy.mjs'
    if (-not (Test-FmCommand 'node')) { return 0 }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $policy))) { return 0 }
    $node = Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { return 0 }

    $result = Invoke-FmTool -FilePath $node.Source -Arguments @(
        (ConvertTo-FmNativePath $policy), '--command', $cmd
    )
    if (-not $result.Ok) { return 0 }

    $output = $result.StdOut.TrimEnd("`n")
    if ([string]::IsNullOrEmpty($output)) { return 0 }

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
    foreach ($fmItem in @(Invoke-FmCdPreToolCheck -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    # Fail open, silently: a guard that cannot decide must be
    # indistinguishable from a guard that allowed.
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
