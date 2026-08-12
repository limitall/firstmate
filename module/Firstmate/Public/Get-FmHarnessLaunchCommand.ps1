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
    [OutputType([string])]
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
    # THE PANE'S SHELL IS NOT PowerShell 7. MEASURED on the captain's laptop: a
    # herdr pane opens `powershell.exe` 5.1, which has no
    # $PSNativeCommandArgumentPassing at all and always applies the legacy
    # command-line quoting - and legacy quoting does not escape a double quote
    # inside the argument. The brief is full of quoted commands, so its own
    # quotes ended the argument early and the next option-shaped token became a
    # flag: a brief containing `-Seconds` aborted the launch outright with
    # `error: unknown option '-Seconds'`, and every other brief arrived
    # silently mangled, which is worse.
    #
    # So the launch is run BY PowerShell 7, whose argument passing is exact. The
    # only text that crosses the 5.1 boundary is this script - which carries no
    # double quote of its own and no brief content, because the brief is still
    # read from disk inside it. ConvertTo-FmPowerShellLiteral does the escaping
    # mechanically rather than by hand-counted quoting.
    $inner = "$prefix$($adapter.Executable) --dangerously-skip-permissions $modelFlag$effortFlag$briefExpr"
    if ($inner.Contains('"')) {
        # "carries no double quote" is the whole reason this survives the 5.1
        # boundary, and everything composed above uses single quotes - so a
        # double quote here means an interpolated VALUE brought one in (a
        # CLAUDE_CONFIG_DIR path, say). Refusing is the only safe answer:
        # emitting it would put us back to a silently mangled brief, which is
        # precisely the failure this wrapper exists to remove.
        throw ('error: the launch command would carry a double quote, which the pane shell (Windows PowerShell ' +
            '5.1) cannot quote safely; remove it from the interpolated value rather than launching a worker ' +
            "whose brief may arrive mangled: $inner")
    }
    "pwsh -NoProfile -Command " + (ConvertTo-FmPowerShellLiteral $inner)
}
