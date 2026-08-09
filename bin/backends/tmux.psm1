# bin/backends/tmux.psm1 - the tmux session-provider adapter.
#
# Twin: bin/backends/tmux.sh
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). The bash
# twin moved the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh and fm-teardown.sh already ran inline into named adapter functions,
# running the EXACT same commands in the EXACT same order. This module runs those
# same command sequences from PowerShell. Imported only through
# bin/fm-backend.psm1's Import-FmBackendAdapter, never directly.
#
# Bash -> PowerShell function map, and each function's RETURN CONVENTION, because
# a bash function has one channel (stdout plus an exit status) and these have
# two. Four packages are being written against this table right now.
#
#   bin/backends/tmux.sh                 this file                          returns
#   -----------------------------------  ---------------------------------  -----------------------------
#   fm_backend_tmux_resolve_bare_selector Resolve-FmBackendTmuxBareSelector  "sess:win" or $null
#   fm_backend_tmux_capture               Get-FmBackendTmuxCapture           RAW stdout, or $null on failure
#   fm_backend_tmux_send_key              Send-FmBackendTmuxKey              [bool]
#   fm_backend_tmux_send_text_submit      Send-FmBackendTmuxTextSubmit       verdict string
#   fm_backend_tmux_container_ensure      Initialize-FmBackendTmuxContainer  session name, or $null
#   fm_backend_tmux_create_task           New-FmBackendTmuxTask              window id, or $null
#   fm_backend_tmux_current_path          Get-FmBackendTmuxCurrentPath       path, or '' on failure
#   fm_backend_tmux_send_text_line        Send-FmBackendTmuxTextLine         [bool]
#   fm_backend_tmux_send_literal          Send-FmBackendTmuxLiteral          [bool]
#   fm_backend_tmux_kill                  Remove-FmBackendTmuxTarget         [bool] (shape validation)
#   fm_backend_tmux_current_command       Get-FmBackendTmuxCurrentCommand    comm, or $null on failure
#   fm_backend_tmux_agent_state           Get-FmBackendTmuxAgentState        state string
#   fm_backend_tmux_agent_alive           Get-FmBackendTmuxAgentAlive        alive|dead|unknown
#
# TRAILING-NEWLINE CONVENTION, stated once and applied consistently. Every
# function above whose bash twin is consumed through `$( ... )` returns the value
# a bash caller ends up holding, i.e. with trailing newlines already stripped.
# Get-FmBackendTmuxCapture is the ONE exception and it is deliberate:
# bin/fm-peek.sh calls fm_backend_capture directly, so the capture's raw bytes
# ARE fm-peek's stdout, and bin/fm-fleet-snapshot.sh pipes it into `head -c`. A
# converted caller that spelled `$( ... )` must therefore TrimEnd([char]10)
# itself; every other function here has already done it.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# live in bin/fm-tmux-lib.psm1, shared with the away-mode daemon exactly as the
# bash pair is. This adapter imports that module and re-exports its submit core
# under the backend's naming convention rather than duplicating it, so the two
# consumers cannot drift apart - and neither can the two language trees.
#
# ---------------------------------------------------------------------------
# WHAT THE POWERSHELL TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. THE TRAILING LABEL PARAMETER IS DECLARED EVEN WHERE IT IS IGNORED. The
#    dispatcher forwards `expected-label` to capture, send-key and
#    send-text-submit for every backend. A bash function ignores extra
#    arguments; a [CmdletBinding()] PowerShell function THROWS on them. tmux has
#    no endpoint-label verification (its window name IS the label, and the
#    dispatcher's own selector resolution already bound it), so the parameter is
#    accepted and unused - which is exactly what the bash twin does with it.
#
# 2. NO `set -e` MEANS EVERY STATUS IS CHECKED. Several bash functions here rely
#    on the CALLER's `set -e` to abort - Send-FmBackendTmuxKey's target
#    verification is the clearest case, where a failed display-message aborts
#    fm-send.sh before send-keys can run. PowerShell has no such mechanism, so
#    the verification result is returned as $false and the caller decides. The
#    guard is preserved, not the abort mechanism.
#
# 3. `LC_ALL=C` IS SCOPED, NOT INHERITED. Get-FmBackendTmuxAgentState pins the
#    locale for its inventory read because it CLASSIFIES tmux's error text, and a
#    localized message would silently turn `missing` into `unreadable`. bash
#    spells that as a command prefix; here the variable is set and restored
#    around the one call in a finally block.
#
# 4. NO SUBPROCESSES FOR STRING WORK. `grep -m1`, `grep -qx` and `grep -Fqx`
#    become in-process matching. The one behavioural nuance that carries is
#    documented at Resolve-FmBackendTmuxBareSelector: `grep ":$name\$"` is a
#    BASIC regular expression, so the name is not a literal, and the small set of
#    characters that are literal in BRE but special in .NET is escaped rather
#    than left to change the match.
#
# WINDOWS NOTE: tmux does not exist on this platform, so no path in this file has
# been smoke-tested against a real tmux server here. Every path IS exercised
# differentially against the bash twin through a fake tmux on PATH by
# tests/fm-backend-core-psm1.test.sh; tests/fm-backend-tmux-smoke.test.sh remains
# the real-server authority for the bash side on a host that has tmux.
#
# Imported through bin/fm-backend.psm1:
#   Import-FmBackendAdapter tmux

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports: a nested Import-Module -Force REMOVES the loaded
# module GLOBALLY first, which would strip a consumer of commands it had already
# imported (verified live; bin/fm-composer-lib.psm1 carries the same note).
Import-Module (Join-Path $PSScriptRoot '..' 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-tmux-lib.psm1')

$script:FmBackendTmuxOrdinal = [System.StringComparison]::Ordinal

# --- selector resolution ------------------------------------------------------

# The characters that are LITERAL in a POSIX basic regular expression (what
# `grep` without -E reads) but SPECIAL in .NET. `. * [ ] ^ $ \` are special in
# both and are deliberately left alone, so a caller relying on BRE metacharacters
# gets the same match in both worlds.
$script:FmBackendTmuxBreOnlyLiterals = [char[]]@('+', '?', '(', ')', '{', '}', '|')

function ConvertTo-FmBackendTmuxBasicRegexPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        if ([Array]::IndexOf($script:FmBackendTmuxBreOnlyLiterals, $ch) -ge 0) { [void]$sb.Append('\') }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
Resolve an ad hoc bare window name against the live tmux inventory.
.DESCRIPTION
Twin of fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback
for a selector that is neither an explicit target nor a task selector routed
through meta. Mirrors the `tmux list-windows -a ... | grep -m1 ":$name\$"`
pipeline that used to be duplicated inside fm-send.sh's and fm-peek.sh's own
resolve().

Returns the FIRST matching "session:window" line, or $null after writing the
same refusal the bash twin writes to stderr.

The pattern is a BASIC regular expression with the name interpolated raw, so the
name is NOT a literal - a name containing `.` genuinely matches any character in
both worlds. See $script:FmBackendTmuxBreOnlyLiterals for the one class of characters
that had to be escaped to keep that true.
#>
function Resolve-FmBackendTmuxBareSelector {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    $result = Invoke-FmTmuxCommand @('list-windows', '-a', '-F', '#{session_name}:#{window_name}')
    $pattern = ':' + (ConvertTo-FmBackendTmuxBasicRegexPattern $Name) + '$'
    $rx = $null
    try {
        $rx = [System.Text.RegularExpressions.Regex]::new($pattern)
    } catch {
        # An unusable pattern makes grep exit non-zero, which the bash twin
        # reports as "no window named ..." - the same outcome, reached here
        # without the grep diagnostic on stderr.
        $rx = $null
    }
    if ($null -ne $rx) {
        $body = $result.StdOut
        if ($body.EndsWith("`n", $script:FmBackendTmuxOrdinal)) { $body = $body.Substring(0, $body.Length - 1) }
        if (-not [string]::IsNullOrEmpty($body)) {
            foreach ($line in $body.Split("`n")) {
                if ($rx.IsMatch($line)) { return $line }
            }
        }
    }
    Write-FmErr "error: no window named $Name"
    return $null
}

# --- reads --------------------------------------------------------------------

<#
.SYNOPSIS
Bounded plain-text pane capture.
.DESCRIPTION
Twin of fm_backend_tmux_capture, mirroring fm-peek.sh's and fm-watch.sh's
`tmux capture-pane -p -t "$T" -S -"$N"`. Returns tmux's RAW stdout - see the
trailing-newline note in the file header for why this one function does not
strip - or $null when tmux failed, which is the twin of its non-zero return.

-ExpectedLabel is accepted and ignored; see note 1 in the file header.
#>
function Get-FmBackendTmuxCapture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare, so this parameter must exist; tmux has no endpoint-label verification to spend it on, exactly as the bash twin ignores it. See note 1 in the file header.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $result = Invoke-FmTmuxCommand @('capture-pane', '-p', '-t', $Target, '-S', "-$Lines")
    if (-not $result.Ok) { return $null }
    return $result.StdOut
}

<#
.SYNOPSIS
The live pane's current working directory, or '' on any tmux error.
.DESCRIPTION
Twin of fm_backend_tmux_current_path, mirroring fm-spawn.sh's worktree-discovery
poll. The empty-on-error contract is load-bearing: fm-spawn polls this until the
pane leaves the project directory, and an exception or a fabricated value would
either abort the spawn or satisfy the poll with a directory the pane never
entered.
#>
function Get-FmBackendTmuxCurrentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $result = Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{pane_current_path}')
    if (-not $result.Ok) { return '' }
    return $result.StdOut.TrimEnd([char]10)
}

<#
.SYNOPSIS
The target's live foreground process name, or $null on any tmux error.
.DESCRIPTION
Twin of fm_backend_tmux_current_command: tmux's own `#{pane_current_command}`,
already resolved from the pty's foreground process group (verified empirically
with real tmux 3.6a - a harness invoked interactively stays the reported command
even while it shells out to subcommands that do not take over the pty, and the
value reverts to the shell's own name only once the foreground command exits).

$null distinguishes "tmux would not answer" from "tmux answered with nothing";
Get-FmBackendTmuxAgentState needs both, and they mean different things.
#>
function Get-FmBackendTmuxCurrentCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $result = Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{pane_current_command}')
    if (-not $result.Ok) { return $null }
    return $result.StdOut.TrimEnd([char]10)
}

# --- writes -------------------------------------------------------------------

<#
.SYNOPSIS
Send one named special key, after verifying the target exists.
.DESCRIPTION
Twin of fm_backend_tmux_send_key, mirroring fm-send.sh's --key path: a
`display-message -p -t <target> '#{pane_id}'` probe first, then `send-keys`.

The probe is not decoration. tmux silently falls back to the ACTIVE window when
a named target is absent, so sending without proving the target exists can
deliver a keystroke into whatever window the captain happens to be looking at.
$false here is the twin of the bash abort that the caller's `set -e` produced
(note 2 in the file header).

-ExpectedLabel is accepted and ignored; see note 1.
#>
function Send-FmBackendTmuxKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare, so this parameter must exist; tmux has no endpoint-label verification to spend it on, exactly as the bash twin ignores it. See note 1 in the file header.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    $probe = Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{pane_id}')
    if (-not $probe.Ok) { return $false }
    $sent = Invoke-FmTmuxCommand @('send-keys', '-t', $Target, $Key)
    return [bool]$sent.Ok
}

<#
.SYNOPSIS
Send one line of text then Enter, with no composer verification.
.DESCRIPTION
Twin of fm_backend_tmux_send_text_line - the fixed spawn-time commands
(`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
inline in fm-spawn.sh. Unverified on purpose: these are commands typed into a
plain shell before any agent exists, not captain instructions into a composer.
#>
function Send-FmBackendTmuxTextLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )
    return [bool](Invoke-FmTmuxCommand @('send-keys', '-t', $Target, $Text, 'Enter')).Ok
}

<#
.SYNOPSIS
Send text as literal bytes with no submission.
.DESCRIPTION
Twin of fm_backend_tmux_send_literal. The caller sends Enter separately -
fm-spawn.sh pauses between the literal send and Enter so the harness can settle.
#>
function Send-FmBackendTmuxLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )
    return [bool](Invoke-FmTmuxCommand @('send-keys', '-t', $Target, '-l', $Text)).Ok
}

<#
.SYNOPSIS
Type text once, then submit and verify, retrying only the submission.
.DESCRIPTION
Twin of fm_backend_tmux_send_text_submit, which re-exports fm_tmux_submit_core
verbatim. Never retypes: a swallowed Enter leaves the text in the composer, and
retyping would duplicate a captain instruction into a live agent. See
bin/fm-tmux-lib.psm1 for the composer-verification contract and the echoed
verdicts; callers require exact `empty` before treating submission as confirmed.

-ExpectedLabel is accepted and ignored; see note 1 in the file header.
#>
function Send-FmBackendTmuxTextSubmit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend, and a CmdletBinding function throws on an argument it did not declare, so this parameter must exist; tmux has no endpoint-label verification to spend it on, exactly as the bash twin ignores it. See note 1 in the file header.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$Settle = '0',
        [Parameter(Position = 5)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    return Send-FmTmuxSubmit -Target $Target -Text $Text -Retries $Retries `
        -EnterSleep $EnterSleep -Settle $Settle
}

# --- lifecycle ----------------------------------------------------------------

<#
.SYNOPSIS
Resolve the session new task windows are created in, creating it if needed.
.DESCRIPTION
Twin of fm_backend_tmux_container_ensure: reuse the current tmux session when
firstmate itself runs inside tmux, else ensure a dedicated detached "firstmate"
session exists. Mirrors fm-spawn.sh's container-ensure block and returns the
resolved session name.

A failed `new-session` still returns 'firstmate', exactly as the bash twin does -
its `has-session || new-session` chain leaves the failure unexamined and falls
through to the printf. The caller's next command against that session is what
surfaces the problem, and inventing a refusal here would diverge.
#>
function Initialize-FmBackendTmuxContainer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrEmpty((Get-FmEnv -Name 'TMUX'))) {
        $result = Invoke-FmTmuxCommand @('display-message', '-p', '#S')
        if (-not $result.Ok) { return $null }
        return $result.StdOut.TrimEnd([char]10)
    }
    $has = Invoke-FmTmuxCommand @('has-session', '-t', 'firstmate')
    if (-not $has.Ok) { $null = Invoke-FmTmuxCommand @('new-session', '-d', '-s', 'firstmate') }
    return 'firstmate'
}

<#
.SYNOPSIS
Create the task's window, refusing an existing window of that name.
.DESCRIPTION
Twin of fm_backend_tmux_create_task, mirroring fm-spawn.sh's
duplicate-check-then-new-window sequence including its exact error text. Returns
the created window's STABLE window id.

Robustness carried over verbatim from the bash twin (fm-spawn tmux window
handling under a non-default captain config):
  - capture a STABLE window id with -P -F '#{window_id}', and let tmux append at
    the next free index by targeting the session with a trailing colon, so a
    non-default base-index cannot collide;
  - PIN the window name by disabling automatic-rename and allow-rename on the
    new window: the captain's tmux may rename the window away from fm-<id> once
    treehouse cd's into the worktree, which would break name-based targeting.
The returned window id lets callers target the window even if its name is ever
lost, so worktree discovery cannot fall back to the active client's window.

A failed inventory read is NOT a refusal: the bash twin pipes list-windows into
grep, so a failure yields empty input, no match, and the create proceeds. tmux
itself then refuses a genuine duplicate.
#>
function New-FmBackendTmuxTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WindowName = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ProjectPath = ''
    )

    $listed = Invoke-FmTmuxCommand @('list-windows', '-t', $Session, '-F', '#{window_name}')
    $body = $listed.StdOut
    if ($body.EndsWith("`n", $script:FmBackendTmuxOrdinal)) { $body = $body.Substring(0, $body.Length - 1) }
    if (-not [string]::IsNullOrEmpty($body)) {
        foreach ($line in $body.Split("`n")) {
            # `grep -qx`: a WHOLE-LINE fixed-string match, ordinal.
            if ([string]::Equals($line, $WindowName, $script:FmBackendTmuxOrdinal)) {
                Write-FmErr "error: window ${Session}:${WindowName} already exists"
                return $null
            }
        }
    }

    $created = Invoke-FmTmuxCommand @(
        'new-window', '-dP', '-F', '#{window_id}', '-t', "${Session}:", '-n', $WindowName, '-c', $ProjectPath)
    if (-not $created.Ok) { return $null }
    $wid = $created.StdOut.TrimEnd([char]10)

    # Best-effort, exactly as the bash `|| true`: an older tmux that rejects one
    # of these options must not fail the spawn.
    $null = Invoke-FmTmuxCommand @('set-window-option', '-t', $wid, 'automatic-rename', 'off')
    $null = Invoke-FmTmuxCommand @('set-window-option', '-t', $wid, 'allow-rename', 'off')
    return $wid
}

<#
.SYNOPSIS
Remove one explicitly named task window, best-effort.
.DESCRIPTION
Twin of fm_backend_tmux_kill. Empty, omitted and malformed targets return $false
BEFORE invoking tmux, so tmux can never interpret an empty target as the
caller's current window - the reason this validation exists at all.

The kill itself is best-effort: an already-gone window is not an error, matching
the inline `tmux kill-window ... || true` this replaced. The `=session:=window`
form pins both halves to exact names so no prefix or fuzzy match can widen the
target.
#>
function Remove-FmBackendTmuxTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if ($null -eq $Target) { $Target = '' }
    $colon = $Target.IndexOf(':')
    if ($colon -lt 0) { return $false }
    $session = $Target.Substring(0, $colon)
    $window = $Target.Substring($colon + 1)
    # The bash guard is `case "$session:$window" in :*|*:|*:*:*)`: an empty
    # session, an empty window, or a target carrying a second colon.
    if ([string]::IsNullOrEmpty($session)) { return $false }
    if ([string]::IsNullOrEmpty($window)) { return $false }
    if ($window.IndexOf(':') -ge 0) { return $false }

    $null = Invoke-FmTmuxCommand @('kill-window', '-t', "=${session}:=${window}")
    return $true
}

# --- recovery-grade agent state ----------------------------------------------

# Harness signatures, exactly as the bash `case` arms are written: the first four
# families match as SUBSTRINGS (so a Windows leaf name like claude.exe still
# matches, and so does a wrapper such as opencode-tui), while the pi family
# matches EXACTLY - `pi` is two characters and a substring rule would classify
# any command containing them as a live agent.
$script:FmBackendTmuxAgentSubstring = [string[]]@('claude', 'codex', 'opencode', 'grok', 'kimi')
$script:FmBackendTmuxAgentExact = [string[]]@('pi', 'pi-signed', 'pi-launcher', 'Pi')
$script:FmBackendTmuxShellExact = [string[]]@('zsh', 'bash', 'sh', 'dash', 'ash', 'ksh', 'mksh', 'tcsh', 'csh', 'fish')

# The tmux responses that authoritatively mean "the endpoint is not there",
# as opposed to "tmux would not tell me". The last two are ANCHORED at the end
# of the message in the bash `case`, and that anchoring is kept.
function Test-FmBackendTmuxInventoryMissing {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    if ($Message.Contains("can't find session:", $script:FmBackendTmuxOrdinal)) { return $true }
    if ($Message.Contains('no server running on ', $script:FmBackendTmuxOrdinal)) { return $true }
    if ($Message.Contains('error connecting to ', $script:FmBackendTmuxOrdinal)) {
        if ($Message.EndsWith(' (No such file or directory)', $script:FmBackendTmuxOrdinal)) { return $true }
        if ($Message.EndsWith(' (Connection refused)', $script:FmBackendTmuxOrdinal)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Recovery-grade harness-agent state for one recorded target.
.DESCRIPTION
Twin of fm_backend_tmux_agent_state. See bin/fm-backend.psm1's
Get-FmBackendAgentState for the shared state vocabulary and
docs/tmux-backend.md "Agent liveness probe" for the empirical basis.

THE SAFETY RULE, and the reason this is not a one-line pane read: tmux silently
falls back to the ACTIVE window when a named target is absent, so the exact
recorded window must appear in a SUCCESSFUL session inventory before its
foreground command can be trusted. An omitted window, or a definitive
missing-session/missing-server response, is `missing`; ANY other inventory or
pane read failure is `unreadable`, so a transient tmux problem never licenses a
duplicate spawn. Only `dead` and `missing` license recovery, and the difference
between the two branches below is the difference between recovering a crew and
double-spawning one.

A malformed target - no colon, an empty half, or a second colon - is
`unreadable` rather than `missing`, because an unparseable record proves nothing
about the endpoint.
#>
function Get-FmBackendTmuxAgentState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if ($null -eq $Target) { $Target = '' }
    $colon = $Target.IndexOf(':')
    if ($colon -lt 0) { return 'unreadable' }
    $session = $Target.Substring(0, $colon)
    $window = $Target.Substring($colon + 1)
    if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($window)) { return 'unreadable' }
    if ($window.IndexOf(':') -ge 0) { return 'unreadable' }

    # LC_ALL=C for this read only: the classification below matches tmux's own
    # ENGLISH error text, and a localized message would read as `unreadable`
    # where the endpoint is authoritatively `missing`.
    $hadLcAll = [Environment]::GetEnvironmentVariable('LC_ALL')
    $listed = $null
    try {
        $env:LC_ALL = 'C'
        $listed = Invoke-FmTmuxCommand @('list-windows', '-t', $session, '-F', '#{window_name}')
    } finally {
        if ($null -eq $hadLcAll) { Remove-Item -LiteralPath 'Env:LC_ALL' -ErrorAction SilentlyContinue }
        else { $env:LC_ALL = $hadLcAll }
    }

    if (-not $listed.Ok) {
        # `2>&1` in the bash twin merges the streams before classifying, because
        # tmux reports this failure on stderr.
        $message = ($listed.StdOut + $listed.StdErr).TrimEnd([char]10)
        if (Test-FmBackendTmuxInventoryMissing $message) { return 'missing' }
        return 'unreadable'
    }

    $inventory = $listed.StdOut.TrimEnd([char]10)
    $found = $false
    if (-not [string]::IsNullOrEmpty($inventory)) {
        foreach ($line in $inventory.Split("`n")) {
            # `grep -Fqx`: fixed-string, whole-line, ordinal.
            if ([string]::Equals($line, $window, $script:FmBackendTmuxOrdinal)) { $found = $true; break }
        }
    }
    if (-not $found) { return 'missing' }

    $comm = Get-FmBackendTmuxCurrentCommand $Target
    if ($null -eq $comm) { return 'unreadable' }
    # `${comm#-}`: a login shell is reported as "-bash".
    if ($comm.StartsWith('-', $script:FmBackendTmuxOrdinal)) { $comm = $comm.Substring(1) }

    foreach ($needle in $script:FmBackendTmuxAgentSubstring) {
        if ($comm.Contains($needle, $script:FmBackendTmuxOrdinal)) { return 'alive' }
    }
    if ([Array]::IndexOf($script:FmBackendTmuxAgentExact, $comm) -ge 0) { return 'alive' }
    if ([Array]::IndexOf($script:FmBackendTmuxShellExact, $comm) -ge 0) { return 'dead' }
    if ([string]::IsNullOrEmpty($comm)) { return 'unreadable' }
    return 'ambiguous'
}

<#
.SYNOPSIS
Backward-compatible three-state view of the agent verdict.
.DESCRIPTION
Twin of fm_backend_tmux_agent_alive, for callers that only need a yes/no. The
detailed state contract is owned by Get-FmBackendTmuxAgentState; everything that
is not confidently alive or confidently gone stays `unknown`, never `dead`.
#>
function Get-FmBackendTmuxAgentAlive {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    switch -CaseSensitive (Get-FmBackendTmuxAgentState $Target) {
        'alive' { return 'alive' }
        'dead' { return 'dead' }
        'missing' { return 'dead' }
        default { return 'unknown' }
    }
}

Export-ModuleMember -Function @(
    'Resolve-FmBackendTmuxBareSelector',
    'Get-FmBackendTmuxCapture', 'Get-FmBackendTmuxCurrentPath', 'Get-FmBackendTmuxCurrentCommand',
    'Send-FmBackendTmuxKey', 'Send-FmBackendTmuxTextLine', 'Send-FmBackendTmuxLiteral',
    'Send-FmBackendTmuxTextSubmit',
    'Initialize-FmBackendTmuxContainer', 'New-FmBackendTmuxTask', 'Remove-FmBackendTmuxTarget',
    'Get-FmBackendTmuxAgentState', 'Get-FmBackendTmuxAgentAlive'
)
