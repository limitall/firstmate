# bin/fm-subagent-pretool-check.ps1 - PreToolUse guard against primary-session
# delegation outside the fleet.
#
# Twin: bin/fm-subagent-pretool-check.sh
#
# A firstmate primary that delegates through a harness's own delegation,
# scheduling, or background-work tool creates work with no `state/<id>.meta` and
# no `data/<id>/brief.md`. Only `bin/fm-spawn.sh` writes that metadata, and
# untracked project work contributes nothing to the in-flight branch of
# bin/fm-supervision-lib.sh or bin/fm-turnend-guard.sh. So such work is not
# merely unsupervised: absent an independent X-mode need, it makes the whole
# guard stack structurally inert, and it dies with the primary session instead
# of living in its own backend session.
#
# This scoped PreToolUse guard is the shipped mechanism.
# Claude primaries should also use an untracked per-home local
# `permissions.deny` list as hardening for known Claude delegation tools,
# because it removes them from the model's schema entirely.
# That deny list must not be tracked: it is Claude-only rather than
# harness-agnostic, and tracked project settings propagate into linked
# worktrees where they disarm legitimate crewmates.
# The tracked Claude matcher is deliberately `.*`: a stem-enumerating matcher
# would reintroduce the fail-open-by-enumeration problem this guard exists to
# solve, because any future tool name outside the matcher would never reach this
# script.
# This script is therefore the single owner of classification.
# It matches a delegation-SHAPED tool name rather than a fixed list, so a future
# tool that ships before anyone updates a local deny list is still refused.
#
# The guard is narrow by design. It classifies ONE thing: the shape of the tool
# name. It makes no judgment about whether the work should be delegated at all,
# which is a reasoning boundary no tool-shape hook can enforce.
# See docs/subagent-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | pwsh -NoProfile -File bin/fm-subagent-pretool-check.ps1
#   pwsh -NoProfile -File bin/fm-subagent-pretool-check.ps1 --tool '<tool-name>'
#
# Stdin mode extracts .tool_name for Claude and Codex, or .toolName for Grok.
# CLI mode is for adapters that already hold the tool name (OpenCode, Pi).
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.ps1):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_SUBAGENT=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES. bin/fm-arm-pretool-check.ps1's header owns the mechanics all
# three transports share. Two are specific to this file:
#
#   THE NORMALIZER IS BYTE WORK, NOT TEXT WORK. bash runs
#   `LC_ALL=C ... tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'`, which folds
#   ASCII only and then DELETES every remaining byte outside [a-z0-9]. The
#   obvious PowerShell spelling, ToLowerInvariant(), is subtly wider: it maps
#   U+212A KELVIN SIGN to 'k', so a tool named with one would normalize to a
#   letter here and be deleted outright under LC_ALL=C. Get-FmSubagentNormalizedTool
#   therefore folds A-Z by hand and keeps only ASCII alphanumerics, which is
#   what the C locale actually does.
#
#   THE ROUTE PROBE ACCEPTS EITHER TWIN. bash tests for bin/fm-scout.sh; this
#   tests for either extension, because contract 7 in docs/powershell-port.md
#   forbids a script from assuming which side of the conversion a sibling is on.
#   The deny TEXT still names bin/fm-scout.sh unchanged - it is the documented
#   route a harness shows the model, and Invoke-FmScript resolves whichever twin
#   exists. Both twins ship side by side for the whole conversion, so the two
#   worlds pick the same branch throughout.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on either: see mechanic 5 in bin/fm-arm-pretool-check.ps1's header.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-primary-scope-lib.psm1')

$fmArgv = @($args)

# Lowercase substrings that mark a tool name as delegation-shaped: it creates
# work, an agent, a schedule, or an isolated workspace that firstmate would not
# know about. This list is the single owner of the shipped classification.
$script:FmDelegationStems = @(
    'agent', 'subagent', 'task', 'workflow', 'cron', 'schedul', 'worktree',
    'delegate', 'spawn', 'dispatch', 'handoff', 'remote', 'sendmessage', 'monitor'
)

# Exact lowercase tool names that match a stem above but only OBSERVE or STOP
# work that already exists. Reading or ending unaccounted work is not creating
# it, and denying these would strand already-running work with no way to inspect
# or end it. A local Claude deny list may still remove these from the
# schema; this shipped guard deliberately stays narrower so it can never be the
# reason a runaway task cannot be stopped.
$script:FmObserveOnlyTools = @(
    'taskoutput', 'taskstop', 'taskget', 'tasklist', 'cronlist', 'bashoutput', 'killshell'
)

# Exact lowercase tool names that match a stem above but create no RUNNABLE
# work. These write only the harness's session-local todo list, which has no
# executor: it spawns no agent, allocates no worktree, registers no schedule,
# and starts nothing that could outlive the session or escape a firstmate
# guard. Denying them stops the primary tracking its own plan while granting no
# delegation power, and the deny text would tell it to run bin/fm-brief.sh for a
# todo entry, so the stem match here is a false positive rather than a policy.
# This is a separate list from FmObserveOnlyTools on purpose: these tools WRITE,
# so folding them into a list documented as observe-or-stop would make that
# contract untrue. Both lists are exact-name, never substring, so neither can
# widen by accident.
$script:FmPlanOnlyTools = @('taskcreate', 'taskupdate')

# The `usage()` heredoc, one array element per line. It still names the .sh
# twin: this text is the documented CLI surface (contract 4), and the two files
# must print the same bytes while both exist.
$script:FmSubagentUsage = @(
    'Usage: fm-subagent-pretool-check.sh [--tool <tool-name>] [--claude]'
    ''
    'With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex'
    'tool_name, or Grok toolName).'
    'Denies a delegation-SHAPED tool name in a genuine primary home.'
    'Claude primaries may also add an untracked per-home permissions.deny list that'
    'removes known delegation tools from the model schema before this hook is needed.'
    'Do not ship that Claude-only list in tracked project settings, because linked'
    'worktrees inherit it and legitimate crewmates would lose their delegation tools.'
    'This hook remains as the shipped guard for future delegation-shaped names'
    'outside any local fixed list.'
    'Fires only in a genuine firstmate primary home; it is a silent no-op in a'
    'crewmate/scout task worktree or any non-firstmate repo, where a worker using'
    'delegation tools is legitimate.'
    'Exits 0 to allow and 2 to deny, naming the real crewmate dispatch path instead.'
    'Set FM_ALLOW_SUBAGENT=1 in the session environment to allow deliberately.'
    'Malformed transport fails open.'
)

<#
.SYNOPSIS
The json_escape() twin: escape backslashes and quotes, then flatten newlines.
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
The `jq -r '(.a // .b // empty)'` twin over an already-parsed payload.
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
Fold a tool name to the C-locale [a-z0-9] form the classification uses.
.DESCRIPTION
Twin of `LC_ALL=C printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'`.
See the CONVERSION NOTES in the header for why this is written by hand instead
of with ToLowerInvariant().
#>
function Get-FmSubagentNormalizedTool {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Tool = '')

    # Compared as CODE POINTS, not as characters: PowerShell's -ge/-le fall back
    # to case-INSENSITIVE string comparison for these operands, so `$c -ge 'A'`
    # would be true for a lowercase letter too and the fold would corrupt it.
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Tool.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -ge 65 -and $code -le 90) { $code += 32 }        # A-Z -> a-z
        if (($code -ge 97 -and $code -le 122) -or ($code -ge 48 -and $code -le 57)) {
            [void]$sb.Append([char]$code)
        }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
The whole guard, returning the process exit code instead of taking it.
#>
function Invoke-FmSubagentPreToolCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $tool = ''
    $toolSet = $false
    $claudeMode = $false

    $i = 0
    while ($i -lt $Arguments.Count) {
        $arg = $Arguments[$i]
        if ($arg -ceq '--tool') {
            if ($i + 1 -ge $Arguments.Count) {
                Write-FmErr 'error: --tool requires a value'
                return 2
            }
            $tool = $Arguments[$i + 1]
            $toolSet = $true
            $i += 2
        } elseif ($arg.StartsWith('--tool=')) {
            $tool = $arg.Substring('--tool='.Length)
            $toolSet = $true
            $i += 1
        } elseif ($arg -ceq '--claude') {
            $claudeMode = $true
            $i += 1
        } elseif ($arg -ceq '-h' -or $arg -ceq '--help') {
            foreach ($line in $script:FmSubagentUsage) { Write-FmOut $line }
            return 0
        } else {
            Write-FmErr "error: unknown argument: $arg"
            foreach ($line in $script:FmSubagentUsage) { Write-FmErr $line }
            return 2
        }
    }

    if (-not $toolSet) {
        $payload = Read-FmHookPayload
        if ($null -eq $payload) { return 0 }
        [string[][]]$toolPaths = @(@('tool_name'), @('toolName'))
        $tool = Get-FmHookPayloadField $payload $toolPaths
    }

    if ([string]::IsNullOrEmpty($tool)) { return 0 }

    $normalized = Get-FmSubagentNormalizedTool $tool

    # An MCP tool belongs to an external integration, not to the harness's own
    # delegation surface, and its name is chosen by that server. Never classify
    # one here: an MCP server with a task or agent noun in a tool name is common
    # and blocking it would be a false positive with no bearing on fleet
    # dispatch. Tested against the RAW name, exactly as the bash `case` is.
    if ($tool.StartsWith('mcp__')) { return 0 }

    foreach ($allowed in ($script:FmObserveOnlyTools + $script:FmPlanOnlyTools)) {
        if ($normalized -ceq $allowed) { return 0 }
    }

    $matched = ''
    foreach ($stem in $script:FmDelegationStems) {
        if ($normalized.Contains($stem)) { $matched = $stem; break }
    }
    if ([string]::IsNullOrEmpty($matched)) { return 0 }

    # The single deliberate escape hatch. It is an environment variable rather
    # than a flag or a state file so it must be set when the session is
    # launched, which makes a genuinely intended use possible and an accidental
    # one impossible: no in-session tool call can set it for the call that
    # follows.
    if ((Get-FmEnv 'FM_ALLOW_SUBAGENT') -ceq '1') { return 0 }

    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        ConvertTo-FmNativePath $rootOverride
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) {
        ConvertTo-FmNativePath $homeEnv
    } elseif ($rootOverride) {
        ConvertTo-FmNativePath $rootOverride
    } else {
        $fmRoot
    }
    $stateOverride = Get-FmEnv 'FM_STATE_OVERRIDE'
    $state = if ($stateOverride) { ConvertTo-FmNativePath $stateOverride } else { Join-Path $fmHome 'state' }

    # Scope to a genuine primary home, exactly as the session-start nudge and
    # the turn-end guard do. Test-FmPrimaryScopeMatch accepts a plain checkout
    # or a marked secondmate home - both operate a fleet and must dispatch
    # through it - and rejects a linked task worktree, which is the shape
    # bin/fm-spawn.sh always hands a crewmate. A crewmate using delegation tools
    # inside its own task worktree is legitimate and stays allowed. Any failure
    # to confirm the home is inert (exit 0), never a block, so a broken
    # environment never denies a call.
    if (-not (Test-FmPrimaryScopeMatch -Root $fmRoot -State $state)) { return 0 }

    # Name the dedicated scout entry point only when this home carries it;
    # degrade to the two-step brief-then-spawn path when it does not, rather
    # than naming a script that is not there. Either twin counts - see the
    # CONVERSION NOTES in the header.
    $scoutBin = Join-Path $fmRoot 'bin'
    $hasScout = [System.IO.File]::Exists((Join-Path $scoutBin 'fm-scout.sh')) -or
                [System.IO.File]::Exists((Join-Path $scoutBin 'fm-scout.ps1'))
    $route = if ($hasScout) {
        'first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'
    } else {
        'first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
    }

    $reason = '[subagent-dispatch] the firstmate primary dispatches through the fleet, not the harness''s own delegation tools: work started that way has no durable fleet record, leaves every firstmate guard inert, and dies with this session. Instead, ' +
        $route + ' (blocked tool: ' + $tool + ', delegation-shaped on "' + $matched + '"). Launch the session with FM_ALLOW_SUBAGENT=1 for a deliberate exception.'

    Write-FmHookDeny -Detail $reason -ClaudeMode:$claudeMode
    return 2
}

$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmSubagentPreToolCheck -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    # Fail open, silently: a guard that cannot decide must be
    # indistinguishable from a guard that allowed.
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
