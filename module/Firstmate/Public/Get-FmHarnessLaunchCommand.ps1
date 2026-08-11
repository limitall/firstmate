#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
The verified launch command for one task, as it will be typed into its pane.

.DESCRIPTION
Ported from bin/fm-spawn.sh's launch_template() plus model_flag_for_harness and
effort_flag_for_harness. This is the name Start-FmWorker resolves when no
explicit launch command was passed, so its parameter set is a cross-area contract
(docs/task-dispatch-windows.md).

THE BRIEF IS NEVER TYPED. The pane reads the brief file itself and prefixes the
operational-input header, exactly as the bash template has the pane run
`$(fm-operational-input.sh encode launch-brief < brief)`. Only the expression
crosses the terminal, so a multi-kilobyte brief cannot be truncated or mangled by
the send path. The Windows pane runs PowerShell, so the same job is one
`Get-Content -Raw` sub-expression with the header prepended.

FAIL CLOSED, THREE WAYS
  - an unknown harness refuses,
  - a known harness with no verified Windows adapter refuses rather than being
    launched with a POSIX-shaped command line into a PowerShell pane,
  - a verified harness whose executable is not on PATH refuses BEFORE an
    endpoint exists, because a pane that opens onto a shell error looks to
    supervision like a wedged worker rather than a missing dependency.
The escape hatch is unchanged from bash: pass a raw launch command to drive an
unverified adapter deliberately.

.EXAMPLE
Get-FmHarnessLaunchCommand -Harness claude -BriefPath C:\fm\data\my-task\brief.md -Model opus -Effort high
#>
function Get-FmHarnessLaunchCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Model = '',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Effort = '',
        [ValidateSet('ship', 'scout', 'secondmate')][string]$Kind = 'ship'
    )
    $adapter = Get-FmHarnessAdapter -Harness $Harness
    if ($null -eq $adapter) {
        throw "error: unknown harness '$Harness'; pass a raw launch command to use an unverified adapter"
    }
    if (-not $adapter.Verified) {
        throw ("error: harness '$Harness' has no verified launch adapter in the Windows port (no evidence that " +
            'its CLI runs and fires turn-end hooks on Windows); select a verified harness or pass a raw launch ' +
            'command to drive an unverified adapter deliberately')
    }
    $null = Assert-FmHarnessExecutable -Harness $Harness

    $header = Get-FmOperationalInputHeader -Kind 'launch-brief'
    $briefExpr = '(' + (ConvertTo-FmPowerShellLiteral $header) +
        ' + (Get-Content -Raw -LiteralPath ' + (ConvertTo-FmPowerShellLiteral $BriefPath) + '))'
    $modelFlag = Get-FmHarnessModelFlag -Harness $Harness -Model $Model
    $effortFlag = Get-FmHarnessEffortFlag -Harness $Harness -Effort $Effort

    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's predicted-next-
    # prompt ghost text, which renders as dim text in an otherwise-empty composer
    # and reads like real typed input when firstmate captures the pane. On Windows
    # herdr's capture is MEASURED to arrive with SGR stripped, so a dim-aware
    # composer reader cannot tell ghost text from real input there - which makes
    # this env var load-bearing on Windows rather than defence in depth.
    $prefix = "`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false'; "
    # A pane is created by a long-lived herdr server that does not inherit
    # firstmate's environment, so a bare `claude` would fall back to the default
    # store even when firstmate itself runs under a different one.
    if ($env:CLAUDE_CONFIG_DIR) {
        $prefix += "`$env:CLAUDE_CONFIG_DIR=" + (ConvertTo-FmPowerShellLiteral $env:CLAUDE_CONFIG_DIR) + '; '
    }
    if ($Kind -eq 'secondmate') {
        # A secondmate is a firstmate instance, so it runs the primary
        # supervision model rather than a crewmate's turn-end-only wiring.
        $prefix += "`$env:FM_SUPERVISION_MODEL='autoarm'; "
    }
    "$prefix$($adapter.Executable) --dangerously-skip-permissions $modelFlag$effortFlag$briefExpr"
}
