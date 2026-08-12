#requires -Version 7.0
# FmDelivery.ps1 - the delivery surface: which delivery modes this port can
# honour, the guarded local landing path (bin/fm-merge-local.sh), and scout ->
# ship promotion (bin/fm-promote.sh).
#
# WHAT THE GUARDS ARE FOR. fm-merge-local is the ONE sanctioned exception to
# "never run state-changing git in projects/": the captain's merge authority
# applied locally instead of through a GitHub PR. Every refusal below is what
# keeps that exception narrow - a local-only task, a branch that exists, a
# project checkout that is on its default branch and clean, and a merge that is
# a clean fast-forward. Nothing is ever forced, stashed, or discarded, and a
# diverged branch is sent back to the crewmate to rebase rather than merged.
#
# The mode gate is the other half. This port ships direct-PR and local-only as
# first-class. no-mistakes is refused BY NAME rather than accepted and then
# silently not run: a task whose meta says mode=no-mistakes would be reported
# as pipeline-gated work by every consumer while nothing on this platform can
# run that pipeline, which is exactly the "appears to work" failure the port
# must not have.

Set-StrictMode -Version Latest

# --- delivery modes -----------------------------------------------------------

# The three task modes bin/fm-promote.sh accepts. no-mistakes-prod-only is
# deliberately NOT here: it is a registry policy, not a task mode, and is
# refused by name with its own message (Get-FmProjectMode -Raw is what reads it).
$script:FmDeliveryTaskModes = @('no-mistakes', 'direct-PR', 'local-only')

# The modes this port can actually deliver. Kept separate from the list above so
# a refusal can say "this is a real mode that this port cannot run" instead of
# "unknown mode", which are different problems with different fixes.
$script:FmDeliverySupportedModes = @('direct-PR', 'local-only')

# Get-FmDeliveryModeSupport: can this port ship a task in <Mode>?
#
# WINDOWS-UNVERIFIED is the wrong label here - this is not unverified, it is
# undecided upstream: the no-mistakes CLI has no established Windows support,
# so the port refuses the mode rather than probing for a binary and hoping the
# pipeline behind it behaves. When no-mistakes gains Windows support, this is
# the single place that changes.
function Get-FmDeliveryModeSupport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        # -Registry asks the question a project registration asks: is this a
        # posture the captain may register? That set includes the conditional
        # policy no-mistakes-prod-only, which is never a task mode.
        [switch]$Registry
    )

    $knownModes = if ($Registry) {
        $script:FmDeliveryTaskModes + @('no-mistakes-prod-only')
    } else {
        $script:FmDeliveryTaskModes
    }
    $known = $knownModes -contains $Mode
    $supported = $script:FmDeliverySupportedModes -contains $Mode
    $reason = ''
    if (-not $known) {
        $reason = if ($Registry) {
            "'$Mode' is not a registered delivery mode; expected one of " + ($knownModes -join ', ')
        } else {
            "'$Mode' is not a task delivery mode; expected one of " + ($knownModes -join ', ')
        }
    } elseif ($Mode -eq 'no-mistakes-prod-only') {
        $reason = 'mode ''no-mistakes-prod-only'' cannot be registered by this Windows port: its product-facing ' +
            'leg runs the no-mistakes pipeline, and that pipeline has no established Windows support, so a ' +
            'project registered under it would look pipeline-gated while nothing here can run the gate. ' +
            'Register direct-PR or local-only, or register this project from a Linux firstmate home.'
    } elseif (-not $supported) {
        $reason = "mode '$Mode' is not supported by this Windows port: the no-mistakes pipeline has no " +
            'established Windows support, and this port refuses a mode it cannot actually run rather than ' +
            'recording it and appearing to gate on a pipeline that never executes. Ship this task ' +
            'direct-PR or local-only, or run it from a Linux firstmate home.'
    }

    [pscustomobject]@{
        Mode      = $Mode
        Known     = $known
        Supported = $supported
        Reason    = $reason
    }
}

# Assert-FmDeliveryModeSupported: the stop-the-command form. Throws, so the
# refusal behaves identically whatever the caller's $ErrorActionPreference is
# (the module's own is 'Stop', a caller's may be 'Continue').
function Assert-FmDeliveryModeSupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [switch]$Registry
    )

    $verdict = Get-FmDeliveryModeSupport -Mode $Mode -Registry:$Registry
    if ($verdict.Supported) { return $true }
    throw "error: $($verdict.Reason)"
}

# --- supervision guard --------------------------------------------------------

# Every one of these commands starts with `fm-guard.sh || true` in bash: an
# advisory supervision check whose failure never blocks the action. The guard is
# owned by another area; when it is absent the step simply did not run, which is
# the correct direction for an advisory check (it never gates anything here).
function Invoke-FmDeliveryGuard {
    [CmdletBinding()]
    param()
    $cmd = Resolve-FmSessionCommand -Name 'Invoke-FmGuard'
    if (-not $cmd) { return @() }
    try {
        return @(& $cmd 2>&1 | ForEach-Object { [string]$_ })
    } catch {
        return @()
    }
}

# --- the per-task lifecycle interlock ----------------------------------------
#
# MERGE POINT RESOLVED. bin/fm-promote.sh takes two locks through
# fm-wake-lib.sh's symlink-owner mutex: a control lock so two lifecycle actions
# cannot run against one task, and a meta lock around the read-modify-write of
# the task record. This area carried a stand-in for both until the lock area
# landed. It has, so the stand-in is gone and both locks are the foundation's:
# Request-FmLock / Unlock-FmLock, with Get-FmMetaLockPath owning the meta-lock
# path. Two things that owner gets right and the stand-in did not:
#
#   - the pid FILE is the lock, not the directory. Removing the directory on
#     release is what broke mutual exclusion (see Request-FmLock), and the
#     stand-in removed the directory.
#   - stale recovery, holder reporting and the break protocol are one
#     implementation for the whole module rather than one per area.
#
# The control-lock PATH has no owner yet - the foundation publishes
# Get-FmMetaLockPath and Get-FmTaskSetLockPath but nothing for bash's
# state/.control-<id>.lock - so this area names it, on the bash path, and uses
# the foundation's mechanism to take it.

function Get-FmDeliveryControlLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir ".control-$TaskId.lock"
}

# --- the local landing path ---------------------------------------------------

# Test-FmMergeLocalReady: every guard bin/fm-merge-local.sh applies, evaluated
# without touching anything. Returned as a verdict rather than thrown so the
# same checks can be reported (a preflight, a test) and enforced (the merge).
#
# The order is the bash order, because the FIRST failing guard is the one whose
# message the operator acts on, and a reordered check would hand them a
# different, less useful instruction.
function Test-FmMergeLocalReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Branch,
        [string]$DefaultBranch = ''
    )

    $refuse = {
        param($Message)
        [pscustomobject]@{
            Ready         = $false
            Reason        = $Message
            Project       = $Project
            Branch        = $Branch
            DefaultBranch = $DefaultBranch
        }
    }

    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        return & $refuse "error: project directory does not exist: $Project"
    }
    $exists = Invoke-FmGit -Directory $Project -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
    if (-not $exists.Ok) {
        return & $refuse "error: branch $Branch does not exist in $Project"
    }
    if (-not $DefaultBranch) { $DefaultBranch = Get-FmGitDefaultBranch -Directory $Project }
    if (-not $DefaultBranch) {
        return & $refuse "error: cannot determine default branch for $Project; expected origin/HEAD, main, or master"
    }

    # The project's main checkout must be on its default branch and clean, so
    # the fast-forward lands predictably (firstmate never writes here otherwise).
    $current = Get-FmGitOutput -Directory $Project -Arguments @('symbolic-ref', '--short', 'HEAD')
    if ($current -ne $DefaultBranch) {
        return & $refuse "error: $Project is on '$current', expected default branch '$DefaultBranch'; cannot merge safely"
    }
    $status = Invoke-FmGit -Directory $Project -Arguments @('status', '--porcelain')
    if (-not $status.Ok) {
        return & $refuse "error: cannot inspect $Project for uncommitted changes; refusing to merge into it"
    }
    if ($status.StdOut.Trim()) {
        return & $refuse "error: $Project has a dirty working tree; refusing to merge into it"
    }

    # Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
    $ancestor = Invoke-FmGit -Directory $Project -Arguments @('merge-base', '--is-ancestor', $DefaultBranch, $Branch)
    if (-not $ancestor.Ok) {
        return & $refuse ("REFUSED: $Branch is not a fast-forward of $DefaultBranch (it has diverged)." + "`n" +
            "Have the crewmate rebase $Branch onto $DefaultBranch, then retry.")
    }

    [pscustomobject]@{
        Ready         = $true
        Reason        = ''
        Project       = $Project
        Branch        = $Branch
        DefaultBranch = $DefaultBranch
    }
}

# --- promotion ----------------------------------------------------------------

# Set-FmTaskPromotionMeta: rewrite one task record from kind=scout to a ship
# task carrying its decided delivery contract.
#
# The bash writes a sibling temp file and moves it over the meta, so a reader
# never sees a half-written record; that is preserved here, and the write goes
# through the LF-only owner so the record stays byte-identical to what a Linux
# firstmate writes. Every OTHER field, and its order, is preserved exactly: only
# kind=, mode= and yolo= are dropped and re-appended, in that order.
function Set-FmTaskPromotionMeta {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MetaPath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Yolo
    )

    if (-not $PSCmdlet.ShouldProcess($MetaPath, 'rewrite the task record as a ship task')) { return $false }

    $lines = @(Get-FmSessionFileLines -Path $MetaPath |
        Where-Object { -not ($_.StartsWith('kind=') -or $_.StartsWith('mode=') -or $_.StartsWith('yolo=')) })
    $lines += @("kind=ship", "mode=$Mode", "yolo=$Yolo")

    $tmp = "$MetaPath.promote.$PID"
    Write-FmTextFileLf -Path $tmp -Text (($lines -join "`n") + "`n")
    if (-not (Move-FmSessionFileInPlace -Source $tmp -Destination $MetaPath)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "error: could not replace the task record at $MetaPath; nothing was changed"
    }
    $true
}

# The ship instructions a promoted crewmate is sent next. A scout has been
# working in scratch: it must return to a clean default-branch base and leave
# its scratch commits behind, carrying over only the changes it intends to ship.
# The bash prints this as a ready-to-run fm-send.sh line; the port prints the
# PowerShell equivalent, because a command a Windows captain cannot paste is not
# a next step.
function Get-FmPromotionNextStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$FirstmateHome
    )

    $quotedHome = "'" + ($FirstmateHome -replace "'", "''") + "'"
    $instructions = "<ship instructions for mode=$Mode`: review scratch state with git status and git log; " +
        "reset to a clean default-branch base; carry over only intended fix changes; " +
        "create branch fm/$TaskId; implement; report done>"
    "next: `$env:FM_HOME = $quotedHome; ./bin/fm-send.ps1 fm-$TaskId '$instructions'"
}
