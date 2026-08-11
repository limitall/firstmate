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
# MERGE POINT. bin/fm-promote.sh takes two locks through fm-wake-lib.sh's
# symlink-owner mutex: a control lock so two lifecycle actions cannot run
# against one task, and a meta lock around the read-modify-write of the task
# record. That library is the lock area's to port. Until it lands, this area
# implements the same two locks on the same paths (state/.control-<id>.lock,
# state/.meta-<id>.lock) with the Windows-native primitive the design report
# names: directory creation, which is atomic on NTFS, with the owner's pid and
# pid-identity written inside exactly as the bash owner dir carries them.
#
# When the lock area lands, delete these three functions and call its owner -
# do not keep both. The on-disk shape is deliberately the bash one so a Linux
# firstmate's fm_lock_try_acquire reads this port's lock as held.

# A lock directory younger than this whose pid file is not readable yet is the
# window between "directory created" and "pid written". Treat it as held, the
# same conclusion fm_lock_mid_acquire_is_fresh reaches.
$script:FmDeliveryLockFreshSeconds = 5

function Get-FmDeliveryLockIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)

    # (pid, start time) is the Windows replacement for /proc/<pid>/stat's
    # starttime field: it defeats PID reuse, which a bare pid check cannot.
    # Formatted invariantly for the same reason the bash original pins LC_ALL=C.
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return '' }
    try {
        return $proc.StartTime.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
    } catch {
        return ''
    }
}

function Test-FmDeliveryLockOwnerAlive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OwnerPid,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OwnerIdentity
    )

    if ($OwnerPid -notmatch '^\d+$') { return $false }
    $proc = Get-Process -Id ([int]$OwnerPid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if (-not $OwnerIdentity) { return $true }
    $identity = Get-FmDeliveryLockIdentity -ProcessId ([int]$OwnerPid)
    # An unreadable identity for a live pid is NOT proof of reuse, so the safe
    # answer is "alive": a lock is never stolen on a guess.
    if (-not $identity) { return $true }
    return ($identity -eq $OwnerIdentity)
}

# New-FmDeliveryLock: take <Path> exclusively, or report who holds it. Returns a
# record with Acquired plus the holding pid when it refused; never throws, so
# every caller decides for itself what a refusal means.
function New-FmDeliveryLock {
    # No ShouldProcess: see the -WhatIf note in the create block below. A lock
    # that can be previewed away is not a lock.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StealStale
    )

    $create = {
        try {
            # Directory creation is the atomic step: it FAILS when the directory
            # already exists, which is what makes it a mutex on NTFS and on any
            # POSIX filesystem alike.
            #
            # -WhatIf:$false deliberately: this is an internal interlock, not a
            # user-visible mutation. Previewing it away would let a -WhatIf run
            # proceed past the very check that says "someone else is in here",
            # and the lock is released in the caller's finally either way.
            $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop -WhatIf:$false -Confirm:$false
        } catch {
            return $false
        }
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'pid'), "$PID`n", $encoding)
        $identity = Get-FmDeliveryLockIdentity -ProcessId $PID
        [System.IO.File]::WriteAllText((Join-Path $Path 'pid-identity'), "$identity`n", $encoding)
        $home_ = if ($env:FM_HOME) { $env:FM_HOME } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $Path 'fm-home'), "$home_`n", $encoding)
        return $true
    }

    if (& $create) {
        return [pscustomobject]@{ Acquired = $true; Path = $Path; HeldByPid = '' }
    }

    $ownerPid = ''
    $ownerIdentity = ''
    foreach ($field in @('pid', 'pid-identity')) {
        $file = Join-Path $Path $field
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $value = ''
        try { $value = ([System.IO.File]::ReadAllText($file)).Trim() } catch { $value = '' }
        if ($field -eq 'pid') { $ownerPid = $value } else { $ownerIdentity = $value }
    }

    if (-not $StealStale) {
        return [pscustomobject]@{ Acquired = $false; Path = $Path; HeldByPid = $ownerPid }
    }

    if (Test-FmDeliveryLockOwnerAlive -OwnerPid $ownerPid -OwnerIdentity $ownerIdentity) {
        return [pscustomobject]@{ Acquired = $false; Path = $Path; HeldByPid = $ownerPid }
    }
    if (-not $ownerPid) {
        # No pid recorded: either mid-acquire (young - held) or a lock whose
        # owner died between mkdir and the pid write (old - stale).
        $age = [double]::MaxValue
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item) { $age = ([datetime]::UtcNow - $item.CreationTimeUtc).TotalSeconds }
        if ($age -lt $script:FmDeliveryLockFreshSeconds) {
            return [pscustomobject]@{ Acquired = $false; Path = $Path; HeldByPid = '' }
        }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
    } catch {
        return [pscustomobject]@{ Acquired = $false; Path = $Path; HeldByPid = $ownerPid }
    }
    if (& $create) {
        return [pscustomobject]@{ Acquired = $true; Path = $Path; HeldByPid = ''; RecoveredFromPid = $ownerPid }
    }
    [pscustomobject]@{ Acquired = $false; Path = $Path; HeldByPid = $ownerPid }
}

# Remove-FmDeliveryLock: release a lock this process owns. Releasing a lock
# someone else now holds is a no-op, never a removal - the bash
# release-only-if-still-owner rule, which is what keeps a slow releaser from
# deleting its successor's lock.
function Remove-FmDeliveryLock {
    # No ShouldProcess, for the same reason as New-FmDeliveryLock: a release
    # that a preview could skip would leave the task locked by a dead command.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $pidFile = Join-Path $Path 'pid'
    $ownerPid = ''
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        try { $ownerPid = ([System.IO.File]::ReadAllText($pidFile)).Trim() } catch { $ownerPid = '' }
    }
    if ($ownerPid -ne [string]$PID) { return $false }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        return $true
    } catch {
        return $false
    }
}

function Get-FmDeliveryControlLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir ".control-$TaskId.lock"
}

function Get-FmDeliveryMetaLockPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir ".meta-$TaskId.lock"
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
