#requires -Version 7.0
# module/Firstmate/Private/FmSecondmate.ps1 - retiring a secondmate home.
#
# THE OWNER THE TEARDOWN REFUSAL USED TO NAME. `bin/fm-teardown.ps1 <id>` on a
# kind=secondmate task refused by name, because retiring one is not tearing down
# a task: a home is a whole firstmate installation with its own state records,
# its own backlog, its own descendant tasks, and a row in the only routing record
# the fleet has. Until this landed, the operator deleted the home directory by
# hand - the unguarded discard firstmate exists to prevent.
#
# THE ONE THING THIS AREA GUARANTEES: nothing is removed until the home is
# PROVEN finished with, and the routing row goes LAST. Every uncertainty is a
# refusal, and a refusal leaves every record - the home, the registry row, the
# launching home's state files - exactly as it found them, so a plain rerun is
# always safe.
#
# THE TWO CLASSES OF REFUSAL, AND WHY -Force SEPARATES THEM
#
#   LIVE     - a descendant process still holds a lock in that home, or a live
#              harness holds its session lock. -Force NEVER overrides this. Force
#              is captain authority to DISCARD WORK; it is not authority to pull
#              a home out from under a running agent, and no captain approval
#              makes that a defined operation.
#   DISCARD  - work under way (a descendant task record, an in-flight backlog
#              item) or work that has not landed. These refuse without -Force and
#              are overridable with -Force plus -DiscardApprovedBy, exactly as
#              ordinary teardown treats the landed-work test.
#
# WHAT IS NOT HERE, AND IS NOT SIMULATED. `.agents/skills/secondmate-provisioning`
# owns the list: home seeding, startup convergence, the liveness sweep,
# cross-home backlog handoff, the re-read nudge, and every remote route are
# absent from this port. Retirement does not quietly acquire any of them, and it
# does not restore process-event state - `AGENTS.md` section 14 records that
# there are no process-to-event sources here to restore.
#
# WHY THE LANDED-WORK TEST IS NOT REIMPLEMENTED. Test-FmTeardownWorktreeSafety
# short-circuits kind=secondmate to 'allow' with the note that the gate is
# elsewhere. This is elsewhere. The gate calls that same owner back with -Kind
# 'ship' so the ORDINARY rules run over the secondmate's own worktree and over
# every project clone in its home. There is exactly one landed-work test in this
# port and this area does not carry a second one.

Set-StrictMode -Version Latest

# --- reading the home --------------------------------------------------------

# Is this path a firstmate home at all? By its LAYOUT: setup creates config/
# data/ state/ projects/ beside each other, on this port and on Linux alike, so
# requiring at least one of them is what stops a mistyped or defaulted path
# being treated as a home and deleted. `home=` DEFAULTS to the project directory
# when a secondmate is spawned without -LabelHome (ConvertTo-FmTaskRecordField),
# so "this path is not a home" reaches here in practice rather than in theory.
#
# NOT the `.fm-secondmate-home` marker Test-FmSecondmateHome reads. That marker
# is written by home SEEDING, which is not ported (`secondmate-provisioning`
# says so), so a home provisioned the documented way here does not carry one -
# and a home a Linux firstmate seeded has the layout anyway. Requiring it would
# refuse every real home on this port; consulting it as well would add a
# cross-area dependency that decides nothing.
function Test-FmSecondmateHomeShape {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HomePath)

    if (-not $HomePath) { return $false }
    if (-not (Test-Path -LiteralPath $HomePath -PathType Container)) { return $false }
    foreach ($leaf in @('state', 'config', 'data', 'projects')) {
        if (Test-Path -LiteralPath (Join-Path $HomePath $leaf) -PathType Container) { return $true }
    }
    $false
}

# Get-FmSecondmateDescendantTask: the task records that home holds. One per
# state/<id>.meta, carrying what a retirement needs to either name it in a
# refusal or release what it owns.
function Get-FmSecondmateDescendantTask {
    [OutputType([object[]], [array])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HomePath)

    $found = [System.Collections.Generic.List[object]]::new()
    if (-not $HomePath) { return @($found) }
    $stateDir = Join-Path $HomePath 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return @($found) }

    foreach ($meta in @(Get-ChildItem -LiteralPath $stateDir -Filter '*.meta' -File -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
        $found.Add([pscustomobject]@{
                Id       = [System.IO.Path]::GetFileNameWithoutExtension($meta.Name)
                MetaPath = $meta.FullName
                Worktree = Get-FmMetaValue -Path $meta.FullName -Key 'worktree'
                Project  = Get-FmMetaValue -Path $meta.FullName -Key 'project'
                LeaseId  = Get-FmMetaValue -Path $meta.FullName -Key 'treehouse_lease_id'
            })
    }
    @($found)
}

# Get-FmSecondmateLiveLock: every lock in that home a LIVE process still holds.
#
# Two lock species live in a home's state/ and both have to be asked, because
# each proves a different kind of liveness:
#   - the session lock state/.lock, a FILE holding a harness pid. Held means a
#     live firstmate session is operating this home right now.
#   - the directory locks (.control-<id>.lock, .meta-<id>.lock, .task-set.lock,
#     .watch.lock, the per-file append locks), each a directory with a `pid`
#     child. Held or mid-claim means a live descendant owns it.
#
# Directories are enumerated by SHAPE - any directory with a `pid` child - not
# from a list of known lock names. A list would silently stop covering a lock
# species added later, and "we found no locks" would be indistinguishable from
# "we did not look for that one".
function Get-FmSecondmateLiveLock {
    [OutputType([object[]], [array])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HomePath)

    $live = [System.Collections.Generic.List[object]]::new()
    if (-not $HomePath) { return @($live) }
    $stateDir = Join-Path $HomePath 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return @($live) }

    $session = Get-FmSessionLockStatus -StatePath $stateDir
    if ($session.State -eq 'held') {
        $live.Add([pscustomobject]@{
                Path = $session.Path; Kind = 'session'; ProcessId = $session.ProcessId
                Detail = $session.Text
            })
    }

    foreach ($candidate in @(Get-ChildItem -LiteralPath $stateDir -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate.FullName 'pid') -PathType Leaf)) { continue }
        $info = Get-FmLockInfo -Path $candidate.FullName
        # 'claiming' is a lock whose pid file is written but not yet readable and
        # is younger than the stale grace. The lock area treats it as held, and so
        # does this: a claim in flight is a live process, and reading it as free
        # would delete the home under an agent that is about to start work.
        if ($info.State -in @('held', 'claiming')) {
            $live.Add([pscustomobject]@{
                    Path = $info.Path; Kind = 'task'; ProcessId = $info.ProcessId
                    Detail = "$($info.State)$(if ($info.ProcessId) { " by pid $($info.ProcessId)" })"
                })
        }
    }
    @($live)
}

# Get-FmSecondmateInFlightTask: that home's OWN backlog items that are in flight.
#
# -IgnoreEnvironment is the point of this call, not a detail. TASKS_AXI_FILE is a
# process-wide override, so without it a retirement run in a shell that has one
# set would answer "no work under way" by reading a DIFFERENT home's backlog -
# most likely the launching home's, which is exactly the file this check must not
# consult. The verdict decides whether a home is deleted, so it reads that home's
# own record or it does not run.
#
# The answer separates "no items" from "could not read it", because those are
# opposite verdicts. A home with no backlog file has no work in flight; a backlog
# that cannot be resolved or parsed proves NOTHING, and a gate that returned an
# empty list for it would delete a home on the strength of a failed read.
function Get-FmSecondmateInFlightTask {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HomePath)

    $answer = [pscustomobject]@{ Readable = $true; Task = @(); Path = ''; Detail = '' }
    if (-not $HomePath) { return $answer }
    try {
        $answer.Path = (Get-FmBacklogConfig -Root $HomePath -IgnoreEnvironment).Path
        if (-not (Test-Path -LiteralPath $answer.Path -PathType Leaf)) { return $answer }
        $answer.Task = @(Get-FmBacklog -Path $answer.Path -State 'in_flight')
    } catch {
        $answer.Readable = $false
        $answer.Detail = $_.Exception.Message
    }
    $answer
}

# --- the gate ----------------------------------------------------------------

# Test-FmSecondmateHomeSafety: is this path a home this teardown may retire at
# all? Separate from the liveness and work checks because it is about IDENTITY,
# and identity is never overridable: no captain approval makes deleting the
# launching home, the checkout, or a project clone a defined operation.
#
# 'gone' is a verdict, not a failure. A home that is already absent is the state
# a retirement interrupted after the home came off disk leaves behind, and a
# rerun has to be able to finish the job - which at that point is the registry
# row.
function Test-FmSecondmateHomeSafety {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstmateHome,
        [Parameter()][AllowEmptyString()][string]$Worktree = '',
        [Parameter()][AllowEmptyString()][string]$Project = ''
    )

    if (-not $HomePath) {
        return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
            "REFUSED: secondmate $TaskId records no home, so there is nothing this retirement could prove finished with.",
            'Its state/<id>.meta needs a home= naming the firstmate home it was launched against; every record is preserved.')
    }

    # NOT $home: PowerShell's $HOME is read-only and assigning to it throws,
    # which is the same hazard a -Home parameter carries here.
    $resolved = Resolve-FmPhysicalPathOrRaw -Path $HomePath
    $forbidden = [ordered]@{
        'the launching firstmate home' = $FirstmateHome
        'this checkout'                = Get-FmRoot
        "task $TaskId's own worktree"  = $Worktree
        "task $TaskId's project clone" = $Project
    }
    foreach ($what in $forbidden.Keys) {
        $other = [string]$forbidden[$what]
        if (-not $other) { continue }
        if (Test-FmPathEqual -Left $resolved -Right (Resolve-FmPhysicalPathOrRaw -Path $other)) {
            return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
                "REFUSED: secondmate $TaskId records its home as $HomePath, which is $what.",
                'That is not a retirable secondmate home - a secondmate is provisioned with `fm-setup.ps1 -FirstmateHome <path> -KeepHomePointer`,',
                'and a home= that landed on one of those paths means no separate home was ever created. Nothing was removed.')
        }
    }

    # An ancestor check as well as an equality one: `home=C:\` or a home one level
    # above the checkout would take the checkout with it, and equality alone would
    # not see that.
    foreach ($what in @('the launching firstmate home', 'this checkout')) {
        $other = Resolve-FmPhysicalPathOrRaw -Path ([string]$forbidden[$what])
        if (-not $other) { continue }
        $prefix = $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if ($other.StartsWith($prefix, $comparison)) {
            return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
                "REFUSED: secondmate $TaskId records its home as $HomePath, which CONTAINS $what ($other).",
                'Removing it would take that with it. Nothing was removed.')
        }
    }

    if (-not (Test-Path -LiteralPath $HomePath -PathType Container)) {
        return New-FmTeardownVerdict -Verdict 'gone'
    }
    if (-not (Test-FmSecondmateHomeShape -HomePath $HomePath)) {
        return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
            "REFUSED: secondmate $TaskId records its home as $HomePath, which holds no state/, config/, data/ or projects/ directory.",
            'That is not the shape `fm-setup.ps1` gives a firstmate home, so this retirement cannot prove what it would be deleting. Nothing was removed.')
    }
    New-FmTeardownVerdict -Verdict 'allow'
}

# Test-FmSecondmateRetirementSafety: THE GATE. Everything a retirement must
# prove before ANY record is touched, in the order that keeps the strongest
# refusal first.
#
#   1. identity     - is this a home we may retire at all?          never forced
#   2. liveness     - does a live process still own something here? never forced
#   3. work under way - a descendant task record, an in-flight item  forced
#   4. unlanded work  - its worktree and its project clones          forced
#
# The two forced steps are skipped WHOLE when -Force is set, and the caller
# records who approved that. The two unforced ones run either way, which is what
# makes "-Force must never override a live descendant" true rather than merely
# documented.
function Test-FmSecondmateRetirementSafety {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstmateHome,
        [Parameter()][AllowEmptyString()][string]$Worktree = '',
        [Parameter()][AllowEmptyString()][string]$Project = '',
        [Parameter()][AllowEmptyString()][string]$Mode = '',
        [switch]$Force
    )

    $identity = Test-FmSecondmateHomeSafety -TaskId $TaskId -HomePath $HomePath `
        -FirstmateHome $FirstmateHome -Worktree $Worktree -Project $Project
    if ($identity.Verdict -eq 'refuse') { return $identity }
    $homeGone = $identity.Verdict -eq 'gone'

    # --- 2. liveness, which -Force does not reach ---------------------------

    if (-not $homeGone) {
        $liveLocks = @(Get-FmSecondmateLiveLock -HomePath $HomePath)
        if ($liveLocks.Count -gt 0) {
            $message = [System.Collections.Generic.List[string]]::new()
            $message.Add("REFUSED: secondmate $TaskId still has a live descendant holding a lock in $HomePath.")
            foreach ($lock in $liveLocks) { $message.Add("  $($lock.Path) - $($lock.Detail)") }
            $message.Add('Stop that agent first (bin/fm-control.ps1 <id> exit), then retire the home.')
            $message.Add('--force does NOT override this: it authorizes discarding work, never removing a home a live process is using.')
            return New-FmTeardownVerdict -Verdict 'refuse' -Message $message
        }
    }

    if ($Force) { return New-FmTeardownVerdict -Verdict 'allow' }

    # --- 3. work under way in ITS OWN home ----------------------------------

    if (-not $homeGone) {
        $backlog = Get-FmSecondmateInFlightTask -HomePath $HomePath
        if (-not $backlog.Readable) {
            # A backlog that cannot be read proves nothing, and this gate exists
            # to prove the home is idle. Fail CLOSED, exactly as every other
            # uncertainty in teardown does.
            # The path can be empty here: a malformed .tasks.toml fails before the
            # backlog is even located, and naming nothing would read as a bug.
            $where = if ($backlog.Path) { "at $($backlog.Path)" } else { "in $HomePath" }
            return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
                "REFUSED: secondmate $TaskId's own backlog $where could not be read, so this retirement cannot prove that home is idle.",
                $backlog.Detail,
                'Repair or remove that file, then retire it. Nothing was removed.')
        }
        $descendants = @(Get-FmSecondmateDescendantTask -HomePath $HomePath)
        $inFlight = @($backlog.Task)
        if ($descendants.Count -gt 0 -or $inFlight.Count -gt 0) {
            $message = [System.Collections.Generic.List[string]]::new()
            $message.Add("REFUSED: secondmate $TaskId still has work under way in its own home $HomePath.")
            foreach ($task in $descendants) {
                $message.Add("  task record $($task.Id) ($($task.MetaPath))")
            }
            foreach ($task in $inFlight) {
                $message.Add("  backlog item in flight: $($task.Id) - $($task.Title)")
            }
            $message.Add('Let that home finish its work, or tear those tasks down in that home first.')
            $message.Add('A forced discard needs the captain''s explicit OK: --force --approved-by "<who approved it>".')
            return New-FmTeardownVerdict -Verdict 'refuse' -Message $message
        }
    }

    # --- 4. unlanded work, by the ORDINARY rules ----------------------------
    #
    # -Kind 'ship' on purpose. The kind carve-out inside the landed-work test
    # exists so the ordinary flow defers to this gate; running it here with the
    # secondmate kind would defer to itself and pass everything.

    $checks = [System.Collections.Generic.List[object]]::new()
    if ($Worktree) {
        $checks.Add([pscustomobject]@{
                What = "secondmate $TaskId's own worktree"; Worktree = $Worktree; Project = $Project; Mode = $Mode
            })
    }
    if (-not $homeGone) {
        $projectsDir = Join-Path $HomePath 'projects'
        if (Test-Path -LiteralPath $projectsDir -PathType Container) {
            foreach ($clone in @(Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue |
                        Sort-Object Name)) {
                $checks.Add([pscustomobject]@{
                        What = "project clone $($clone.Name) in $HomePath"
                        Worktree = $clone.FullName; Project = $clone.FullName; Mode = ''
                    })
            }
        }
    }

    foreach ($check in $checks) {
        $verdict = Test-FmTeardownWorktreeSafety -Worktree $check.Worktree -Project $check.Project `
            -Kind 'ship' -Mode $check.Mode
        # A lock-blocked verdict is NOT a pass. The stale-lock recovery protocol
        # belongs to the worktree the task itself owns; a home is not retired on
        # an inspection that could not run.
        if ($verdict.Verdict -eq 'allow') { continue }
        $message = [System.Collections.Generic.List[string]]::new()
        $message.Add("REFUSED: secondmate $TaskId cannot be retired while $($check.What) holds work that has not landed.")
        foreach ($line in $verdict.Message) { $message.Add("  $line") }
        $message.Add('Land or push that work, or get the captain''s explicit OK to discard it, then --force --approved-by "<who approved it>".')
        $message.Add('Nothing was removed and every record is preserved.')
        return New-FmTeardownVerdict -Verdict 'refuse' -Message $message
    }

    New-FmTeardownVerdict -Verdict 'allow'
}

# --- releasing what the home legitimately owns -------------------------------

# Remove-FmSecondmateDescendantLease: return every descendant's leased worktree
# to its pool BEFORE the home comes off disk.
#
# WHY THIS EXISTS AT ALL. A descendant's state/<id>.meta is the only record that
# names its lease. Deleting the home first would leave the pool holding a lease
# with nothing left anywhere that says which worktree it is - the same invisible
# still-held lease the ordinary teardown refuses to create by keeping its state
# files when a return fails. So the leases are released first and a failure to
# release REFUSES, rather than being noted and walked past.
#
# It reaches descendants only on the forced path in practice, since an
# unforced retirement refuses while any descendant record exists at all.
function Remove-FmSecondmateDescendantLease {
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][string]$TaskId
    )

    $returned = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $descendants = @(Get-FmSecondmateDescendantTask -HomePath $HomePath |
            Where-Object { $_.Worktree -and (Test-Path -LiteralPath $_.Worktree -PathType Container) })
    if ($descendants.Count -eq 0) {
        return [pscustomobject]@{ Outcome = 'nothing-to-do'; Returned = @(); Failed = @() }
    }

    # Named before anything is returned, exactly as the ordinary flow does: no
    # treehouse means no descendant lease can be released, and finding that out
    # halfway through would leave some released and some orphaned.
    if (-not (Test-FmTeardownTreehouseAvailable)) {
        return [pscustomobject]@{
            Outcome  = 'unavailable'
            Returned = @()
            Failed   = @("treehouse is not installed, so the $($descendants.Count) leased worktree(s) this home's tasks hold cannot be returned")
        }
    }
    if (-not $PSCmdlet.ShouldProcess($HomePath, "return $($descendants.Count) descendant worktree(s) to their pools")) {
        return [pscustomobject]@{ Outcome = 'skipped'; Returned = @(); Failed = @() }
    }

    foreach ($task in $descendants) {
        $project = if ($task.Project) { $task.Project } else { $task.Worktree }
        $result = Invoke-FmTeardownWorktreeReturn -Worktree $task.Worktree -Project $project `
            -Label "secondmate $TaskId descendant $($task.Id)" -LeaseId $task.LeaseId -TaskId $task.Id -Confirm:$false
        if ($result.Outcome -eq 'returned') {
            $returned.Add("$($task.Id) -> $($task.Worktree)")
        } else {
            $failed.Add("$($task.Id) ($($task.Worktree)): $($result.Outcome) $($result.Detail)".Trim())
        }
    }
    [pscustomobject]@{
        Outcome  = $(if ($failed.Count -gt 0) { 'failed' } else { 'returned' })
        Returned = @($returned)
        Failed   = @($failed)
    }
}

# --- removing the home -------------------------------------------------------

# Remove-FmSecondmateHome: take the home off disk, having re-proved its identity
# first.
#
# The identity check runs AGAIN here even though the gate already ran it. This is
# the one call in the port that recursively deletes a directory an operator named
# in a state file, and the gate and this function are separated by every
# destructive step of the teardown; a re-check costs four path comparisons and
# removes the class of bug where a later edit reorders the two.
#
# A partial removal is reported as a FAILURE, never as success: Windows refuses
# a delete while anything holds a handle, so "some of it went" is precisely the
# case where the caller must keep the registry row and the state records that
# still point at what is left.
function Remove-FmSecondmateHome {
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstmateHome,
        [Parameter()][AllowEmptyString()][string]$Worktree = '',
        [Parameter()][AllowEmptyString()][string]$Project = ''
    )

    $identity = Test-FmSecondmateHomeSafety -TaskId $TaskId -HomePath $HomePath `
        -FirstmateHome $FirstmateHome -Worktree $Worktree -Project $Project
    if ($identity.Verdict -eq 'refuse') {
        return [pscustomobject]@{ Ok = $false; Outcome = 'refused'; Detail = ($identity.Message -join ' ') }
    }
    if ($identity.Verdict -eq 'gone') {
        return [pscustomobject]@{ Ok = $true; Outcome = 'already-gone'; Detail = $HomePath }
    }
    if (-not $PSCmdlet.ShouldProcess($HomePath, "remove secondmate $TaskId's firstmate home")) {
        return [pscustomobject]@{ Ok = $false; Outcome = 'skipped'; Detail = 'not confirmed' }
    }

    $detail = ''
    try {
        Remove-Item -LiteralPath $HomePath -Recurse -Force -ErrorAction Stop
    } catch {
        $detail = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $HomePath) {
        $remaining = @(Get-ChildItem -LiteralPath $HomePath -Recurse -Force -ErrorAction SilentlyContinue |
                Select-Object -First 3 | ForEach-Object { $_.FullName })
        $named = if ($remaining.Count -gt 0) { " Still present: $($remaining -join '; ')." } else { '' }
        return [pscustomobject]@{
            Ok      = $false
            Outcome = 'failed'
            Detail  = ("$HomePath was not fully removed$(if ($detail) { ": $detail" }).$named").Trim()
        }
    }
    [pscustomobject]@{ Ok = $true; Outcome = 'removed'; Detail = $HomePath }
}

# --- the routing record, LAST ------------------------------------------------

# Test-FmSecondmateRegistryRow: does this line record THIS secondmate?
#
# data/secondmates.md is hand-maintained and has no parser (the provisioning
# skill says so in as many words), so the match is the same whole-token rule
# Remove-FmProject uses to find a project reference in the same file. The token
# boundary is what stops `sm-demo` matching a row for `sm-demo-2`.
function Test-FmSecondmateRegistryRow {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Line,
        [Parameter(Mandatory)][string]$TaskId
    )
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    $Line -match "(^|[^A-Za-z0-9_-])$([regex]::Escape($TaskId))([^A-Za-z0-9_-]|$)"
}

# Remove-FmSecondmateRegistryRow: drop this secondmate's row from
# data/secondmates.md, and nothing else.
#
# THIS IS THE LAST STEP OF A RETIREMENT, and the order is the reason: the file is
# the only routing record the fleet has, so while a row is present a home is
# findable. Removing it before the home was gone would leave an untracked home on
# disk that nothing names.
#
# Every untouched line is re-emitted byte for byte. A wrapped row's indented
# continuation lines go with it, because leaving those behind would corrupt the
# very readability the file depends on. Removed lines are RETURNED so the caller
# can print exactly what went - a hand-maintained file deserves an auditable
# edit, not a silent one.
function Remove-FmSecondmateRegistryRow {
    [OutputType([pscustomobject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$TaskId
    )

    $path = Join-Path $DataDir 'secondmates.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Outcome = 'no-registry'; Path = $path; Removed = @() }
    }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($path) } catch {
        return [pscustomobject]@{ Outcome = 'unreadable'; Path = $path; Removed = @(); Detail = $_.Exception.Message }
    }

    $lines = @(($text -replace "`r`n", "`n") -split "`n")
    $keep = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not (Test-FmSecondmateRegistryRow -Line $line -TaskId $TaskId)) {
            $keep.Add($line)
            continue
        }
        $removed.Add($line)
        # A wrapped list item continues on lines that are indented and are not
        # themselves a new item; they belong to the row being removed.
        if ($line -match '^\s*([-*+]|\d+\.)\s') {
            while (($i + 1) -lt $lines.Count -and
                $lines[$i + 1] -match '^\s+\S' -and $lines[$i + 1] -notmatch '^\s*([-*+]|\d+\.)\s') {
                $i++
                $removed.Add($lines[$i])
            }
        }
    }
    if ($removed.Count -eq 0) {
        return [pscustomobject]@{ Outcome = 'no-row'; Path = $path; Removed = @() }
    }
    if (-not $PSCmdlet.ShouldProcess($path, "remove secondmate $TaskId's routing row")) {
        return [pscustomobject]@{ Outcome = 'skipped'; Path = $path; Removed = @() }
    }
    # Write-FmTextFileLf, because this file is part of the byte-for-byte shared
    # contract with a Linux firstmate reading the same home.
    Write-FmTextFileLf -Path $path -Text ($keep -join "`n")
    [pscustomobject]@{ Outcome = 'removed'; Path = $path; Removed = @($removed) }
}
