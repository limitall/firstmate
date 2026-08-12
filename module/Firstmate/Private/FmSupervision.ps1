#requires -Version 7.0
<#
    Private/FmSupervision.ps1 - the renderers behind Get-FmSupervisionInstructions
    (Public/FmSupervision.ps1). Port of bin/fm-supervision-instructions.sh and its
    docs/supervision-protocols/*.md snippets.

    WHY THIS FILE MATTERS MORE HERE THAN IN BASH. On Linux this renderer prints
    one of six harness protocols. This port dispatches exactly one harness, so
    what it really has to get right is the OTHER axis: whether an automatic
    re-arm owner exists in this build at all. Until it does, the Claude
    Stop-hook auto-arm is registered and inert, and the session itself has to
    keep the cycle. Emitting the Stop-owned protocol in that state would tell
    the captain a mechanism is running when nothing is, which is the exact
    failure this port exists to avoid - so the protocol is selected from the
    seam that is actually present, not from a constant.

    Two call shapes bind here, and both are load-bearing:

      Get-FmSupervisionInstructions -Harness <n> -ReadOnly <0|1> -Afk <0|1> -XMode <0|1>
          the session-start digest's stage 4, published in docs/session-start.md.
          Returns the whole block as lines.

      Get-FmSupervisionInstructions <options-hashtable>
          the guard and turn-end banners, through Get-FmSupervisionRepairLine ->
          Invoke-FmSeam, which passes ONE positional hashtable. With
          RepairLine = $true it returns a single sentence.

    Declaring only one of the two would not fail loudly: the seam call would
    throw and the guard would silently keep its generic fallback sentence
    forever. So both are declared, and tests/FmSupervision.Tests.ps1 pins both.
#>

Set-StrictMode -Version Latest

$script:FmSupervisionRule = '================================================================================'

# The bash `bool_value` helper. Every caller spells these differently - the
# digest passes ints, the guards pass bools - and a silent [bool]'0' -> $true
# would invert away-mode and read-only handling, which is not a state to guess.
function Get-FmSupervisionFlag {
    [OutputType([bool])]
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [switch]) { return $Value.IsPresent }
    if ($Value -is [int]) { return ($Value -ne 0) }
    $text = ([string]$Value).Trim()
    return ($text -in @('1', 'true', 'TRUE', 'True', 'yes', 'YES', 'Yes'))
}

# Does this build have an owner that can establish a watcher cycle on its own?
# Probed rather than assumed: the Stop auto-arm resolves the same name, so this
# answer and the hook's behaviour cannot disagree.
function Test-FmSupervisionAutoArmAvailable {
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    return [bool](Get-Command -Name 'Invoke-FmWatchArm' -ErrorAction SilentlyContinue)
}

# The one-sentence repair instruction guards and turn-end banners print. Same
# precedence as bash repair_line(): read-only first, then away mode, then the
# prefixes, then the harness sentence.
function Get-FmSupervisionRepairSentence {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Harness,
        [bool]$ReadOnly,
        [bool]$Afk,
        [bool]$XMode,
        [bool]$QueuePending
    )

    if ($ReadOnly) {
        return 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    }
    if ($Afk) {
        return 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    }

    $prefix = ''
    if ($QueuePending) { $prefix = 'After draining queued wakes, ' }
    if ($XMode) { $prefix += 'source the X-mode environment first, then ' }

    if ($Harness -eq 'claude' -and (Test-FmSupervisionAutoArmAvailable)) {
        return $prefix + 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
    }
    if ($Harness -eq 'claude') {
        return $prefix + 'no automatic re-arm exists in this build, so repair supervision by running bin/fm-watch.ps1 in the FOREGROUND before ending the turn; never background it.'
    }
    return $prefix + 'repair missing watcher supervision according to the session-start operating block for this harness; never background the watcher.'
}

# The ordinary-wake continuation, the line the wake-handling turn acts on.
function Get-FmSupervisionOrdinaryWakeLine {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Harness)

    if ($Harness -eq 'claude' -and (Test-FmSupervisionAutoArmAvailable)) {
        return '- Ordinary wake: the Stop-owned automatic arm already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
    }
    return '- Ordinary wake: drain, handle the wake, then start the next FOREGROUND bin/fm-watch.ps1 cycle yourself while supervision is still needed.'
}

# The Claude protocol for a build whose automatic arm owner has landed. This
# describes machinery that exists in this repo today (Invoke-FmClaudeStopAutoArm
# and the registered Stop hook); only its arm dependency decides which of the
# two protocols is the true one, which is why the choice is probed.
function Get-FmSupervisionClaudeArmedProtocol {
    [OutputType([array])]
    [CmdletBinding()]
    param()
    @(
        'Mode: Claude Stop-hook-owned supervision.'
        ''
        'When this session owns supervision and away mode is not active:'
        '1. Drain first with `pwsh bin/fm-wake-drain.ps1`.'
        '   After handling all emitted wakes and reconciling open decisions, run the exact `-AckThrough` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.'
        '2. Routine arm and re-arm are owned by the Stop hook, never by you. Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle.'
        '3. On a Stop-hook wake (`signal:`, `stale:`, `check:`, or `heartbeat`), drain first and handle the wake. Do not arm another cycle after an ordinary wake.'
        '4. On the one automatic-mechanism failure notice, drain, inspect the failure, and do not turn the notice into a repeating manual-arm loop.'
        '5. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.'
        '6. The turn-end guard is the final backstop, not permission to skip the live cycle.'
        '7. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.'
        ''
        'The watcher itself is `bin/fm-watch.ps1`. One cycle per home; re-arm attaches to a healthy existing cycle rather than starting a second.'
    )
}

# The Claude protocol for THIS build. AGENTS.md section 8 states the same
# obligation in prose; this is the machine-emitted form of it, so the session
# gets the procedure rather than only the rule.
function Get-FmSupervisionClaudeManualProtocol {
    [OutputType([array])]
    [CmdletBinding()]
    param()
    @(
        'Mode: Claude, session-kept FOREGROUND supervision cycle.'
        ''
        'The Stop-hook auto-arm is registered but INERT in this build: it has no arm owner to call, so nothing re-arms the watcher for you. Keep exactly one cycle yourself.'
        ''
        '1. Drain first with `pwsh bin/fm-wake-drain.ps1`.'
        '   After handling every emitted wake and reconciling open decisions, run the exact `-AckThrough` command printed as `WAKE_ACK_REQUIRED`; before that acknowledgement an interruption leaves the work durable for idempotent re-handling.'
        '2. While any work is under way, run `pwsh bin/fm-watch.ps1` in the FOREGROUND.'
        '   It blocks, absorbs the benign wakes, and exits on the first actionable one with a single reason line. That exit IS the wake.'
        '3. Handle the wake, drain again, then start the next foreground cycle while supervision is still needed.'
        '   Never end a turn with work in flight on the assumption that something else is watching.'
        '4. Never background the watcher with `&`, Start-Job, or Start-Process. A child reaped when the tool call returns leaves NO watcher running and a false "already running" read off the dying process.'
        '5. One cycle per home. `watcher: already running pid <N>` means a healthy cycle already exists - leave it alone rather than starting a second.'
        '6. The turn-end guard is a structural backstop, not permission to omit the live cycle.'
        '7. Waiting on a healthy cycle is silent: empty polls and elapsed time are not captain-facing progress.'
    )
}

function Get-FmSupervisionUnknownProtocol {
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Harness)

    $lines = @('Mode: unverified harness fallback.')
    if ($Harness -and $Harness -ne 'unknown') {
        $lines += ''
        $lines += "This port has no verified watcher wake adapter for '$Harness', and does not dispatch it. Only claude is verified here (AGENTS.md section 4)."
    }
    $lines += @(
        ''
        'Follow the generic supervision contract in AGENTS.md section 8.'
        'First cycle: drain queued wakes with `pwsh bin/fm-wake-drain.ps1`, then choose a supervision wait this harness can actually wake from.'
        'Ordinary wake: drain, handle all emitted wakes, reconcile open decisions, run the exact `-AckThrough` command printed as `WAKE_ACK_REQUIRED`, then repeat that verified wait while supervision is still required.'
        'Use a bounded FOREGROUND wait over `pwsh bin/fm-watch.ps1` unless the harness has a tracked background mechanism that survives the tool call and notifies on process exit.'
        'Never background the watcher with `&`, Start-Job, or Start-Process.'
        ''
        'Record new verification evidence in docs/windows-e2e-evidence.md before promoting a harness to a named protocol.'
    )
    $lines
}
