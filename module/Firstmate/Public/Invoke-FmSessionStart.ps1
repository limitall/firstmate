#requires -Version 7.0

<#
.SYNOPSIS
    One command for the whole session start: emits the full ordered startup digest.

.DESCRIPTION
    Port of bin/fm-session-start.sh. Prints the nine-stage digest in the exact
    order the captain reads it - lock, bootstrap, wake-queue, supervision
    instructions, read-once contract, fleet state, network checks, context, next
    step - and always succeeds: this is a reporting command, not a gate. A lock
    refusal is reported as a loud banner inline, never a silent failure.

    NO NETWORK ON THE BLOCKING PATH. Every network check a session start owes is
    started as one detached bounded worker right after the lock and harvested at
    the NETWORK CHECKS stage without ever blocking on it.

    Composition, not duplication: the lock, wake drain, guard, supervision block,
    backend probes, and deferred network stage are owned by other areas of this
    module and resolved by name at call time. A missing owner is reported in the
    digest as a step that did NOT run, never as a step that passed. The expected
    names are listed in docs/session-start.md.

.PARAMETER Reemit
    This process ALREADY took the helm at its own startup and has only lost its
    context (a /clear or a compaction). Skips the mutating sweeps that startup
    already reconciled and re-emits the rest. Wake-queue presentation is NOT
    skipped: queued records arrived after startup and are this turn's work.

.PARAMETER Bounded
    Run the whole digest as one bounded child process (FM_SESSION_START_TIMEOUT,
    default 120s) and print a loud STARTUP TRUNCATED banner naming the stage that
    did not finish if the bound is hit. This is what the session-open hook uses.

.PARAMETER EntryScript
    Path to bin/fm-session-start.ps1, used only with -Bounded to start the child.

.EXAMPLE
    Invoke-FmSessionStart

.EXAMPLE
    Invoke-FmSessionStart -Reemit
#>
function Invoke-FmSessionStart {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Reemit,
        [switch]$Bounded,
        [string]$EntryScript
    )

    if ($Bounded) {
        if ([string]::IsNullOrEmpty($EntryScript)) {
            $EntryScript = Join-Path (Get-FmSessionPaths).Root 'bin' 'fm-session-start.ps1'
        }
        if (-not (Test-Path -LiteralPath $EntryScript -PathType Leaf)) {
            # Without an entry script there is no child to bound, and a session
            # start that does not run at all is far worse than an unbounded one.
            Write-Output "SESSION START: runtime bound skipped - entry script not found at $EntryScript; running the digest unbounded in this process."
            Get-FmSessionStartDigest -Reemit:$Reemit
            return
        }
        Invoke-FmSessionStartBounded -EntryScript $EntryScript -Reemit:$Reemit
        return
    }

    Get-FmSessionStartDigest -Reemit:$Reemit
}

<#
.SYNOPSIS
    The one-line "take the helm" instruction for a resumed or forked session.

.DESCRIPTION
    Port of bin/fm-sessionstart-nudge.sh, and the owner the Claude SessionStart
    hook resolves for its `resume`, `reload` and `fork` routes. Without it those
    routes returned nothing at all: a session that came back after a resume was
    never told to run its session start, so it carried on with no lock, no
    digest and no supervision, and nothing said so.

    It prints ONLY for a genuine firstmate primary whose current harness session
    has not already acquired this home's lock. Three silences, each deliberate:

      - a gate agent (not a concept this port has - see AGENTS.md section 14 -
        so its absent owner simply never suppresses anything here),
      - a session whose root and state do not scope to this primary, which is
        how a task worktree is kept from running a session start for a home it
        does not own,
      - a session that already holds the lock, because it has already taken the
        helm and a second nudge would make it re-run startup.

    EVERY path returns quietly rather than throwing. This runs on Claude's
    SessionStart hook, where a failure blocks session initialization, so there
    is no error worth reporting that is more valuable than the session opening.

.EXAMPLE
    Invoke-FmSessionStartNudge
#>
function Invoke-FmSessionStartNudge {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $paths = Get-FmSessionPaths

        $gateAgent = Resolve-FmSessionCommand -Name 'Test-FmGateAgent'
        if ($gateAgent) {
            try { if (& $gateAgent -Root $paths.Root) { return } }
            catch { Write-Debug "session-start nudge: Test-FmGateAgent owner failed; treating this session as not a gate agent: $_" }
        }

        $scope = Resolve-FmSessionCommand -Name 'Test-FmHookPrimaryScope'
        if ($scope) {
            $inScope = $false
            try { $inScope = [bool](& $scope -Root $paths.Root -State $paths.State) }
            catch { $inScope = $false }
            if (-not $inScope) { return }
        }

        # Ancestry membership, not a pid comparison: the lock names the harness
        # process, and this hook runs several levels below it inside Claude's
        # own worker chain.
        $ownedBySelf = Resolve-FmSessionCommand -Name 'Test-FmSessionLockOwnedBySelf'
        if ($ownedBySelf) {
            $owned = $false
            try { $owned = [bool](& $ownedBySelf -State $paths.State) } catch { $owned = $false }
            if ($owned) { return }
        }

        return (ConvertTo-FmOperationalInput -Kind 'session-start' `
                -Body 'Run `bin/fm-session-start.ps1` now, exactly once, before executing any other instructions.')
    } catch {
        Write-Debug "session-start nudge: suppressed so session initialization is never blocked: $_"
        return
    }
}
