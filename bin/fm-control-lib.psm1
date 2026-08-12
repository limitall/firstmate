# fm-control-lib.psm1 - the ONE PowerShell owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Twin: bin/fm-control-lib.sh
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control is the CONTROL plane: allowlisted lifecycle verbs
# addressed to an exact task id, with the per-harness mechanics owned here
# rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be imported by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.ps1's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.psm1's Get-FmBackendAgentState) able to PROVE that an
#      agent stopped. A verb whose postcondition cannot be proven on the
#      recorded backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.
#
# ---------------------------------------------------------------------------
# HOW THE BASH TWIN'S TWO-CHANNEL ANSWERS ARE SPELLED HERE
#
# Every table in the bash twin answers on two channels at once: it PRINTS a
# value and it RETURNS a status, and several tables use the pair to say three
# different things - "here is the value", "this harness is known and needs
# nothing", and "this harness is not in the table at all". PowerShell has one
# return channel, so the distinction is carried in the value:
#
#   $null   the argument is not in the table (bash `return 1`)
#   ''      the argument IS in the table and its answer is deliberately empty
#           (bash prints nothing and returns 0)
#   <text>  the table's value
#
# Both empty answers are [string]::IsNullOrEmpty, which is what every call site
# in this tree actually branches on - the bash callers collapse them too
# (`clear=$(...) || return 0` then `[ -n "$clear" ] || return 0`). The
# distinction is preserved anyway so a future caller that needs "unknown
# harness" as its own case can have it without a second table.
#
# Array-valued tables (Get-FmControlHarnessWiringPath) return `, @(...)` so an
# empty or single-element answer survives PowerShell's unrolling. Assignment
# strips the comma, so callers must NOT re-wrap in @() and must parenthesize
# the call before piping (docs/powershell-port.md).
#
# Case sensitivity is the bash twin's: `case` matches bytes, so every
# comparison here is ordinal, and `claude*`-style arms are ordinal StartsWith
# rather than PowerShell's case-insensitive -like.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOT -Force: a nested -Force import REMOVES the loaded module globally and
# strips its commands from every session state that had imported it
# (docs/powershell-port.md).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

<#
.SYNOPSIS
The complete control-plane verb allowlist.
.DESCRIPTION
Twin of fm_control_verbs, which prints one verb per line. Returned as an array
with the `, @(...)` guard so a caller can print, join, or index it; the ORDER is
part of the contract because the refusal path in bin/fm-control.ps1 prints this
list verbatim.
#>
function Get-FmControlVerb {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('interrupt', 'exit', 'relaunch')
}

<#
.SYNOPSIS
Is <Verb> an allowlisted control-plane verb? Twin of fm_control_verb_allowed.
#>
function Test-FmControlVerbAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Verb = '')

    if ($null -eq $Verb) { return $false }
    return ($Verb -ceq 'interrupt' -or $Verb -ceq 'exit' -or $Verb -ceq 'relaunch')
}

<#
.SYNOPSIS
Are this harness's control mechanics verified? Twin of
fm_control_harness_supported.
.DESCRIPTION
Mirrors AGENTS.md section 4's verified-adapter list; an unverified adapter is
refused rather than guessed at, exactly as a spawn on it would be.
#>
function Test-FmControlHarnessSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    if ($null -eq $Harness) { return $false }
    switch -CaseSensitive ($Harness) {
        'claude' { return $true }
        'codex' { return $true }
        'opencode' { return $true }
        'pi' { return $true }
        'pi-signed' { return $true }
        'grok' { return $true }
        'kimi' { return $true }
        'muse' { return $true }
        default { return $false }
    }
}

<#
.SYNOPSIS
The verified adapter a RECORDED harness value belongs to, or $null.
.DESCRIPTION
Twin of fm_control_harness_family. Every table in this module is keyed by the
exact verified adapter name, but a task launched from a raw command records the
command's basename instead (bin/fm-spawn derives harness= that way), which is
why the spawn adapters match `claude*`, `muse*`, and friends. This is the one
place that prefix rule is stated. `pi` and `pi-signed` are exact because a `pi*`
prefix would swallow the signed adapter, and an unrecognized value returns $null
rather than being guessed into a family.
#>
function Get-FmControlHarnessFamily {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$RecordedHarness = '')

    if ($null -eq $RecordedHarness) { return $null }
    if ($RecordedHarness -ceq 'pi') { return 'pi' }
    if ($RecordedHarness -ceq 'pi-signed') { return 'pi-signed' }
    $ordinal = [System.StringComparison]::Ordinal
    if ($RecordedHarness.StartsWith('claude', $ordinal)) { return 'claude' }
    if ($RecordedHarness.StartsWith('codex', $ordinal)) { return 'codex' }
    if ($RecordedHarness.StartsWith('opencode', $ordinal)) { return 'opencode' }
    if ($RecordedHarness.StartsWith('grok', $ordinal)) { return 'grok' }
    if ($RecordedHarness.StartsWith('kimi', $ordinal)) { return 'kimi' }
    if ($RecordedHarness.StartsWith('muse', $ordinal)) { return 'muse' }
    return $null
}

<#
.SYNOPSIS
Is <Harness> verified to run a task of <Kind>? Twin of
fm_control_harness_supports_kind.
.DESCRIPTION
muse is a crewmate/scout adapter only: it has no primary supervision protocol,
and bin/fm-spawn refuses a --secondmate launch on it. The control plane asks
this BEFORE it stops anything, so an incompatible relaunch target is refused
while the current agent is still running rather than after it has been stopped.
#>
function Test-FmControlHarnessSupportsKind {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Kind = ''
    )

    if (-not (Test-FmControlHarnessSupported $Harness)) { return $false }
    if ($Harness -ceq 'muse' -and $Kind -ceq 'secondmate') { return $false }
    return $true
}

<#
.SYNOPSIS
The key that cancels a running turn, or $null for an unknown harness.
.DESCRIPTION
Twin of fm_control_interrupt_key. Escape for every adapter except grok, whose
Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
#>
function Get-FmControlInterruptKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    switch -CaseSensitive ($Harness) {
        'claude' { return 'Escape' }
        'codex' { return 'Escape' }
        'opencode' { return 'Escape' }
        'pi' { return 'Escape' }
        'pi-signed' { return 'Escape' }
        'kimi' { return 'Escape' }
        'muse' { return 'Escape' }
        'grok' { return 'C-c' }
        default { return $null }
    }
}

<#
.SYNOPSIS
How many times the interrupt key must be delivered, or 0 for an unknown harness.
.DESCRIPTION
Twin of fm_control_interrupt_repeat. OpenCode needs a double Escape; every other
verified adapter interrupts on a single press. bash prints the count as text and
returns nonzero for an unknown harness; 0 carries that here, and it is also the
count that makes the caller's send loop do nothing - the safe direction if a
caller ever forgets to check.
#>
function Get-FmControlInterruptRepeat {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    switch -CaseSensitive ($Harness) {
        'opencode' { return 2 }
        'claude' { return 1 }
        'codex' { return 1 }
        'pi' { return 1 }
        'pi-signed' { return 1 }
        'grok' { return 1 }
        'kimi' { return 1 }
        'muse' { return 1 }
        default { return 0 }
    }
}

<#
.SYNOPSIS
The key that must follow the interrupt key to leave the composer empty.
.DESCRIPTION
Twin of fm_control_interrupt_clear_key. muse is the one verified adapter that
RESTORES the cancelled prompt into its composer as real bright text, so an
interrupt is not complete until Ctrl+U has cleared it; leaving it there would
make the next submitted line - a steer, or the control plane's own exit command
- concatenate onto it.

Returns 'C-u' for muse, '' for a verified adapter that needs no clear, and $null
for a harness with no verified mechanics (bash's nonzero return).
#>
function Get-FmControlInterruptClearKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    switch -CaseSensitive ($Harness) {
        'muse' { return 'C-u' }
        'claude' { return '' }
        'codex' { return '' }
        'opencode' { return '' }
        'pi' { return '' }
        'pi-signed' { return '' }
        'grok' { return '' }
        'kimi' { return '' }
        default { return $null }
    }
}

<#
.SYNOPSIS
The adapter-owned cancellation acknowledgement this harness exposes.
.DESCRIPTION
Twin of fm_control_interrupt_ack_source: 'muse-session-terminal' for muse,
'none' for every other verified adapter, $null for an unknown one.
#>
function Get-FmControlInterruptAckSource {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    switch -CaseSensitive ($Harness) {
        'muse' { return 'muse-session-terminal' }
        'claude' { return 'none' }
        'codex' { return 'none' }
        'opencode' { return 'none' }
        'pi' { return 'none' }
        'pi-signed' { return 'none' }
        'grok' { return 'none' }
        'kimi' { return 'none' }
        default { return $null }
    }
}

<#
.SYNOPSIS
The command that exits the agent from its own composer, or $null.
.DESCRIPTION
Twin of fm_control_exit_command.
#>
function Get-FmControlExitCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    switch -CaseSensitive ($Harness) {
        'claude' { return '/exit' }
        'opencode' { return '/exit' }
        'grok' { return '/exit' }
        'kimi' { return '/exit' }
        'muse' { return '/exit' }
        'codex' { return '/quit' }
        'pi' { return '/quit' }
        'pi-signed' { return '/quit' }
        default { return $null }
    }
}

<#
.SYNOPSIS
Can <Backend> deliver the named key? Twin of fm_control_backend_supports_key.
.DESCRIPTION
Every session provider normalizes Enter, Ctrl+C, and the Ctrl+U composer clear;
Orca's terminal API exposes only an interrupt and an Enter, so it can deliver
neither Escape nor Ctrl+U (bin/backends/orca.psm1's Send-FmBackendOrcaKey).
#>
function Test-FmControlBackendSupportsKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = ''
    )

    # Plain conditionals rather than a `switch` with a scriptblock arm: the
    # bash twin's outer `case` groups four backends on one pattern, and an
    # if-chain says that with no ambiguity about fall-through.
    if ($Backend -ceq 'tmux' -or $Backend -ceq 'herdr' -or
        $Backend -ceq 'zellij' -or $Backend -ceq 'cmux') {
        return ($Key -ceq 'Escape' -or $Key -ceq 'Enter' -or $Key -ceq 'C-c' -or $Key -ceq 'C-u')
    }
    if ($Backend -ceq 'orca') {
        return ($Key -ceq 'Enter' -or $Key -ceq 'C-c')
    }
    return $false
}

<#
.SYNOPSIS
Does <Backend> have a recovery-grade agent-state classifier?
.DESCRIPTION
Twin of fm_control_backend_state_verified. Only tmux and herdr implement a real
Get-FmBackendAgentState; zellij, orca, and cmux report `unverified`, so no
reading of theirs can prove an agent stopped. The control plane refuses a
stop-proving verb there instead of reporting an unprovable transition as
success.
#>
function Test-FmControlBackendStateVerified {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Backend = '')

    return ($Backend -ceq 'tmux' -or $Backend -ceq 'herdr')
}

<#
.SYNOPSIS
The per-task wiring artifacts a harness leaves behind, or $null when the
arguments cannot name a task.
.DESCRIPTION
Twin of fm_control_harness_wiring_paths, so a relaunch that changes harness (or
re-arms the same one with a fresh busy generation) can clear the previous
incarnation's wiring instead of leaving a stale hook pointing at a retired
generation. Yields zero or more absolute paths: worktree-resident hook files and
firstmate-owned state tokens only, never a harness's own managed config.

An empty worktree, state dir, or id is bash's `return 1` and answers $null here;
a harness with no wiring answers an EMPTY array, which is bash printing nothing
and returning 0.
#>
function Get-FmControlHarnessWiringPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Worktree = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Id = ''
    )

    if ([string]::IsNullOrEmpty($Worktree) -or [string]::IsNullOrEmpty($StateDir) -or
        [string]::IsNullOrEmpty($Id)) {
        return $null
    }
    switch -CaseSensitive ($Harness) {
        'claude' { return , @("$Worktree/.claude/settings.local.json") }
        'opencode' { return , @("$Worktree/.opencode/plugins/fm-busy-state.js") }
        'pi' { return , @("$StateDir/$Id.pi-ext.ts") }
        'pi-signed' { return , @("$StateDir/$Id.pi-ext.ts") }
        'grok' {
            return , @("$Worktree/.fm-grok-turnend", "$StateDir/$Id.grok-turnend-token")
        }
        'kimi' {
            return , @("$Worktree/.fm-kimi-turnend", "$StateDir/$Id.kimi-turnend-token")
        }
        'muse' {
            # muse installs no hook: its busy source is its own session event
            # log, bound to the pane by these two firstmate-owned sidecars. A
            # relaunch ONTO muse rewrites them, but a relaunch AWAY from muse
            # must retire them so no retired incarnation's session binding
            # outlives the agent.
            return , @("$StateDir/$Id.muse-session", "$StateDir/$Id.muse-session-current")
        }
        default { return , @() }
    }
}

<#
.SYNOPSIS
The firstmate-owned global turn-end registry entry a harness mints per task.
.DESCRIPTION
Twin of fm_control_harness_turnend_token_path. grok and kimi are the two
adapters whose turn-end hook is global and gated by a private token file; every
other adapter's wiring is fully covered by Get-FmControlHarnessWiringPath.
Returns the registry path, '' for a harness that mints none, or $null when the
state dir or id is empty (bash's `return 1`).
#>
function Get-FmControlHarnessTurnendTokenPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$StateDir = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Id = ''
    )

    if ([string]::IsNullOrEmpty($StateDir) -or [string]::IsNullOrEmpty($Id)) { return $null }
    switch -CaseSensitive ($Harness) {
        'grok' { return "$StateDir/$Id.grok-turnend-token" }
        'kimi' { return "$StateDir/$Id.kimi-turnend-token" }
        default { return '' }
    }
}

<#
.SYNOPSIS
The global hook-registry file a turn-end token authorizes, or '' when there is
none to name.
.DESCRIPTION
Twin of fm_control_harness_turnend_auth_path. The token is a path component, so
an empty one or one holding anything outside [A-Za-z0-9._-] answers '' - bash
`return 0` with no output, deliberately NOT an error, because the caller's job
is then simply to have nothing to remove. A harness other than grok or kimi
answers '' for the same reason.

GROK_HOME and HOME are read with bash `${VAR:-default}` semantics through
fm-common's Get-FmEnv. HOME is used exactly as the twin uses it, with no
USERPROFILE fallback: firstmate's grok and kimi registries live where the bash
tree put them, and inventing a second location would orphan the real one.
#>
function Get-FmControlHarnessTurnendAuthPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Token = ''
    )

    if ([string]::IsNullOrEmpty($Token)) { return '' }
    if (-not [regex]::IsMatch($Token, '\A[A-Za-z0-9._-]+\z')) { return '' }
    switch -CaseSensitive ($Harness) {
        'grok' {
            $grokHome = Get-FmEnv -Name 'GROK_HOME' -Default ((Get-FmEnv -Name 'HOME') + '/.grok')
            return "$grokHome/hooks/fm-turn-end.d/$Token"
        }
        'kimi' {
            return (Get-FmEnv -Name 'HOME') + "/.kimi-code/fm-turn-end.d/$Token"
        }
        default { return '' }
    }
}

Export-ModuleMember -Function @(
    'Get-FmControlVerb', 'Test-FmControlVerbAllowed',
    'Test-FmControlHarnessSupported', 'Get-FmControlHarnessFamily',
    'Test-FmControlHarnessSupportsKind',
    'Get-FmControlInterruptKey', 'Get-FmControlInterruptRepeat',
    'Get-FmControlInterruptClearKey', 'Get-FmControlInterruptAckSource',
    'Get-FmControlExitCommand',
    'Test-FmControlBackendSupportsKey', 'Test-FmControlBackendStateVerified',
    'Get-FmControlHarnessWiringPath',
    'Get-FmControlHarnessTurnendTokenPath', 'Get-FmControlHarnessTurnendAuthPath'
)
