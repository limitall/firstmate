# bin/fm-fleet-sync.ps1 - refresh project clones: fast-forward the checked-out
# local default branch to origin/<default> when safe, and prune local branches
# whose upstream tracking branch is gone (the remote branch was deleted, i.e. its
# PR merged) and that no worktree still needs.
#
# Twin: bin/fm-fleet-sync.sh
#
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of origin/<default>) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded
# ("recovered:"). Every other off-default state - a non-default named branch, a
# detached HEAD with unique commits, a dirty tree, or a diverged default - may
# hold real work, so it is left untouched and reported as a quantified, loud
# "STUCK: ... N commits behind ... - needs attention" warning rather than a quiet
# drift. Nothing is ever forced, stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# Invoke-FetchWithPackedRefsLockGuard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
#
# Usage: fm-fleet-sync.ps1 [<project-dir-or-name>]
# The single-project form accepts either a path (absolute, or relative to the
# caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
# this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.ps1 dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
#
# ---------------------------------------------------------------------------
# THIS IS ONE OF THE VERY FEW PATHS ALLOWED TO TOUCH A PROJECT CHECKOUT
#
# AGENTS.md hard rule 1 forbids firstmate writing into projects/; the guarded
# fleet-sync is a named exception, and it stays an exception only because every
# write it performs is a CLEAN FAST-FORWARD or a branch deletion that is already
# proven redundant. So the conversion preserves, one for one:
#
#   - `git merge --ff-only` as the only content-moving command. No merge, no
#     rebase, no reset, no stash, no checkout of a branch that is not free.
#   - The re-attach recovery's FOUR simultaneous preconditions (detached, clean,
#     HEAD is an ancestor of the base, <default> not checked out in another
#     worktree, and local <default> itself safe). Dropping any one of them would
#     let the recovery strand a commit.
#   - The prune guards: never the checked-out branch, never a branch that still
#     has a worktree, and only when the upstream is `[gone]`.
#   - Every refusal's exact wording, because a session-start refresh relays these
#     lines to the captain verbatim and the STUCK text is what makes a chronically
#     stuck clone visible.
#
# ---------------------------------------------------------------------------
# PATH SPELLING
#
# Every git call goes through Invoke-FmTool with ConvertTo-FmNativePath applied,
# because git.exe cannot resolve an MSYS `/f/...` path. The LABEL, by contrast, is
# derived from the path as this script resolved it, so a clone under this home's
# projects dir still labels as its bare basename in both worlds; only the
# explicit-outside-path form prints a full path, and there the two worlds
# legitimately spell the same directory differently.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-lock-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force
# Imported explicitly for Resolve-FmPhysicalDirectory: a module's own imports land
# in its PRIVATE session state, so fm-ff-lib pulling this in does not publish it
# here. Declaring the edge is the rule for every converted consumer.
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

# No param() block - see bin/fm-operational-input.ps1's header for why.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $fmRoot = $context.Root
    $projectsDir = $context.Projects
    $binDir = Join-Path $fmRoot 'bin'

    # `"$FM_ROOT/bin/fm-guard.sh" || true`, before any argument handling, so the
    # `--help` path prints it too.
    $null = Invoke-FmScript -Name 'fm-guard' -BinDir $binDir -Stream

    # --- bounded recovery knobs -----------------------------------------------
    #
    # A git ref rewrite (fetch --prune, branch -D, pack-refs) killed after
    # creating .git/packed-refs.lock but before renaming it - e.g. bootstrap's
    # fleet-sync timeout kill, or teardown's process kills - leaves a lock that
    # makes the next sync's fetch fail with Git's "Unable to create
    # '...packed-refs.lock': File exists". These knobs bound the
    # patience-then-provably-stale-clear recovery.
    $lockRetries = Get-FmEnv 'FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES' '3'
    $lockRetryWait = Get-FmEnv 'FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS' '1'
    $lockAgeSecs = Get-FmEnv 'FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS' '30'
    # `case ... in ''|*[!0-9]*)` - a NON-NEGATIVE decimal integer and nothing
    # else; no sign, no whitespace, no float. [int]::TryParse would accept "+3"
    # and " 3", so the digit test is spelled out.
    if ($lockRetries -notmatch '^[0-9]+$') { $lockRetries = '3' }
    if ($lockAgeSecs -notmatch '^[0-9]+$') { $lockAgeSecs = '30' }
    if ($lockRetryWait -notmatch '^([0-9]+([.][0-9]*)?|[.][0-9]+)$') {
        Write-FmErr "fleet-sync: invalid packed-refs lock retry wait '$lockRetryWait'; using 1s"
        $lockRetryWait = '1'
    }
    $lockRetriesN = [int]$lockRetries
    $lockWaitSeconds = [double]::Parse($lockRetryWait, [System.Globalization.CultureInfo]::InvariantCulture)

    $usage = { Write-FmErr 'usage: fm-fleet-sync.sh [<project-dir-or-name>]' }

    if ($fmArgv.Count -ge 1 -and (([string]$fmArgv[0]) -ceq '--help' -or ([string]$fmArgv[0]) -ceq '-h')) {
        & $usage
        Exit-FmScript 0
    }
    if ($fmArgv.Count -gt 1) {
        & $usage
        Exit-FmScript 1
    }

    # --- helpers ---------------------------------------------------------------

    # `[ -d "$p" ]`, tolerant of a path .NET considers malformed (an argument that
    # was never a path at all still has to answer "no", not throw).
    function Test-ProjDirectory {
        param([AllowEmptyString()][string]$Path)
        if ([string]::IsNullOrEmpty($Path)) { return $false }
        try { return (Test-Path -LiteralPath (ConvertTo-FmNativePath $Path) -PathType Container) }
        catch { return $false }
    }

    # `basename` semantics: trailing separators are stripped before the last
    # component is taken, and a path that is nothing but separators is itself.
    function Get-Basename {
        param([string]$Path)
        $p = $Path.TrimEnd('/', '\')
        if ($p -eq '') { return $Path }
        $slash = $p.LastIndexOfAny([char[]]@('/', '\'))
        if ($slash -lt 0) { return $p }
        return $p.Substring($slash + 1)
    }

    function Invoke-ProjGit {
        param([string]$Directory, [string[]]$Arguments)
        return (Invoke-FmTool -FilePath 'git' -Arguments (@('-C', (ConvertTo-FmNativePath $Directory)) + $Arguments))
    }

    # `$(cmd)`: trailing newlines stripped, nothing else touched.
    function Get-CmdOut {
        param([AllowEmptyString()][string]$Text)
        if ($null -eq $Text) { return '' }
        return $Text.TrimEnd("`n")
    }

    # The 2>&1 twin used by the fetch and merge reporters: Invoke-FmTool keeps the
    # streams separate, so they are concatenated in stdout-then-stderr order. git
    # writes its "fatal: ..." to stderr with an empty stdout, so the FIRST LINE -
    # which is all first_line keeps - is identical.
    function Get-CombinedOut {
        param([hashtable]$Result)
        return ($Result.StdOut + $Result.StdErr).TrimEnd("`n")
    }

    # True when git stderr shows the packed-refs.lock "File exists" race. The lock
    # path can appear anywhere in the message (git prefixes it with the failed ref
    # op, e.g. "could not delete reference ...:"). Other "File exists" errors must
    # not match.
    function Test-PackedRefsLockError {
        param([AllowEmptyString()][string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $false }
        return [bool]($Text -match "Unable to create ['`"].*packed-refs\.lock['`"]: File exists")
    }

    # Absolute path to the clone's packed-refs.lock, or '' when it cannot be
    # resolved. `git rev-parse --git-path` answers RELATIVE (".git/packed-refs.lock")
    # for a normal clone in both worlds, which is the branch the bash takes too.
    # A drive-absolute answer is also treated as absolute here: the bash's `/*`
    # test would prepend the worktree to "F:/..." and produce a path that names
    # nothing, and refusing to mangle it can only make the guard MORE accurate.
    function Get-PackedRefsLockPath {
        param([string]$Directory)
        $result = Invoke-ProjGit -Directory $Directory -Arguments @('rev-parse', '--git-path', 'packed-refs.lock')
        if (-not $result.Ok) { return '' }
        $lock = Get-CmdOut $result.StdOut
        if ($lock -eq '') { return '' }
        if ($lock.StartsWith('/') -or $lock -match '^[A-Za-z]:[\\/]') { return $lock }
        $abs = Resolve-FmPhysicalDirectory -Directory $Directory
        if ($null -eq $abs) { return '' }
        return "$abs/$lock"
    }

    # --- the fetch guard -------------------------------------------------------
    #
    # Run `git -C <proj> fetch origin --prune --quiet`, tolerating an orphaned
    # packed-refs.lock left by a killed ref rewrite. Returns a result object with
    # Ok, ExitCode and Output (the git command's combined output, the bash's
    # FETCH_OUTPUT). On the packed-refs.lock signature ONLY: retry up to
    # $lockRetriesN times (a transient lock self-clears as the owning process
    # exits), then - only if the lock is provably stale per fm-lock-lib.psm1
    # (still present, mtime age past the threshold, no live holder of the lock or
    # of the clone worktree) - remove it and retry once more. A live lock, an
    # unprovable one, or any other failure keeps today's behavior. Every wait,
    # retry, and removal prints to stderr, and a successful recovery also prints
    # one "<label>: recovered: ..." summary to stdout so a session-start refresh
    # (which discards fleet-sync stderr) still surfaces it.
    function Invoke-FetchWithPackedRefsLockGuard {
        param([string]$Directory, [string]$Label)

        $fetch = Invoke-ProjGit -Directory $Directory -Arguments @('fetch', 'origin', '--prune', '--quiet')
        $output = Get-CombinedOut $fetch
        if ($fetch.Ok) { return @{ Ok = $true; ExitCode = 0; Output = $output } }
        if (-not (Test-PackedRefsLockError $output)) {
            return @{ Ok = $false; ExitCode = $fetch.ExitCode; Output = $output }
        }

        $rc = $fetch.ExitCode
        $lock = Get-PackedRefsLockPath -Directory $Directory
        $lockDesc = if ($lock -ne '') { $lock } else { 'packed-refs.lock' }
        $attempt = 0
        while ($attempt -lt $lockRetriesN) {
            $attempt++
            Write-FmErr ("${Label}: fetch blocked by packed-refs lock ($lockDesc); waiting " +
                "${lockRetryWait}s and retrying ($attempt/$lockRetriesN) (owning process may be exiting)")
            Start-Sleep -Milliseconds ([int][System.Math]::Round($lockWaitSeconds * 1000))
            $fetch = Invoke-ProjGit -Directory $Directory -Arguments @('fetch', 'origin', '--prune', '--quiet')
            $output = Get-CombinedOut $fetch
            $rc = $fetch.ExitCode
            if ($fetch.Ok) {
                Write-FmErr "${Label}: fetch succeeded on retry; packed-refs lock cleared on its own"
                # One stdout summary so a session-start refresh (which discards
                # fleet-sync stderr and relays only stdout) still surfaces it.
                Write-FmOut "${Label}: recovered: packed-refs lock cleared on its own during retry"
                return @{ Ok = $true; ExitCode = 0; Output = $output }
            }
            if (-not (Test-PackedRefsLockError $output)) {
                return @{ Ok = $false; ExitCode = $rc; Output = $output }
            }
        }

        # Retries exhausted and still the lock signature. Clear ONLY if provably
        # stale. The companion liveness dir is the clone worktree: a live
        # `git -C <proj>` keeps its cwd there even in the narrow window after it
        # closes packed-refs.lock and before it exits, so a holder check on the
        # worktree still catches one the lock-file check alone would miss.
        $lock = Get-PackedRefsLockPath -Directory $Directory
        if ($lock -ne '' -and (Test-Path -LiteralPath (ConvertTo-FmNativePath $lock))) {
            if (Test-FmLockProvablyStale -Lock $lock -Directory $Directory `
                    -MinimumAgeSeconds $lockAgeSecs -LogPrefix 'fleet-sync') {
                $removed = $true
                try { [System.IO.File]::Delete((ConvertTo-FmNativePath $lock)) } catch { $removed = $false }
                if (-not $removed) {
                    Write-FmErr "${Label}: failed to remove provably-stale packed-refs lock $lock; leaving it in place"
                    return @{ Ok = $false; ExitCode = $rc; Output = $output }
                }
                Write-FmErr ("${Label}: removed provably-stale packed-refs lock $lock " +
                    "(age >= ${lockAgeSecs}s, no live holder) and retrying fetch")
                $fetch = Invoke-ProjGit -Directory $Directory -Arguments @('fetch', 'origin', '--prune', '--quiet')
                $output = Get-CombinedOut $fetch
                $rc = $fetch.ExitCode
                if ($fetch.Ok) {
                    Write-FmErr "${Label}: fetch succeeded after stale packed-refs lock cleanup"
                    Write-FmOut "${Label}: recovered: removed a stale packed-refs lock (no live holder)"
                    return @{ Ok = $true; ExitCode = 0; Output = $output }
                }
                return @{ Ok = $false; ExitCode = $rc; Output = $output }
            }
            Write-FmErr ("${Label}: fetch blocked by packed-refs lock $lock that persisted across " +
                "$lockRetriesN retries and is not provably stale (may belong to a live process); leaving it in place")
            return @{ Ok = $false; ExitCode = $rc; Output = $output }
        }
        Write-FmErr ("${Label}: fetch packed-refs lock signature persisted across $lockRetriesN retries " +
            'even after the lock file disappeared')
        return @{ Ok = $false; ExitCode = $rc; Output = $output }
    }

    # --- prune -----------------------------------------------------------------

    # The branch names some worktree of the clone has checked out.
    function Get-WorktreeBranch {
        param([string]$Directory)
        $result = Invoke-ProjGit -Directory $Directory -Arguments @('worktree', 'list', '--porcelain')
        $branches = [System.Collections.Generic.List[string]]::new()
        if ([string]::IsNullOrEmpty($result.StdOut)) { return $branches }
        foreach ($line in ($result.StdOut -split "`n")) {
            if ($line.StartsWith('branch refs/heads/', [System.StringComparison]::Ordinal)) {
                $branches.Add($line.Substring('branch refs/heads/'.Length))
            }
        }
        # Unary comma: PowerShell UNROLLS a collection on the way out of a
        # function, so a bare `return $branches` would hand back $null for an
        # empty result and a bare string for a one-element one - and the
        # `.Contains(...)` guard below would then throw or compare wrongly. The
        # comma keeps the List intact, which is what makes the ordinal
        # whole-string Contains (the `grep -Fxq` twin) available.
        return , $branches
    }

    # Delete local branches whose upstream tracking branch is gone - the remote
    # branch was deleted, which in this fleet means its PR merged - as long as
    # nothing still needs them. Never the checked-out branch, and never a branch
    # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
    # "no worktree" already proves the work landed: teardown removes a branch's
    # worktree only after confirming the work reached the remote. We deliberately
    # do NOT also require the branch to be an ancestor of origin/<default> - PRs in
    # this fleet are squash-merged, so a merged branch is never an ancestor and
    # such a check would prune nothing. The no-worktree guard is the real safety
    # net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
    function Invoke-PruneGoneBranch {
        param([string]$Directory, [string]$Label)
        if ((Get-FmEnv 'FM_FLEET_PRUNE' '1') -ceq '0') { return }

        $worktreeBranches = Get-WorktreeBranch -Directory $Directory
        $head = Invoke-ProjGit -Directory $Directory -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
        $current = ''
        if ($head.Ok) { $current = Get-CmdOut $head.StdOut }

        $refs = Invoke-ProjGit -Directory $Directory -Arguments @(
            'for-each-ref', '--format=%(refname:short) %(upstream:track)', 'refs/heads')
        if ([string]::IsNullOrEmpty($refs.StdOut)) { return }
        foreach ($refline in ($refs.StdOut -split "`n")) {
            if ($refline -eq '') { continue }
            # ${refline%% *} / ${refline#* }: a line with no space leaves track
            # equal to the whole line, which is then not "[gone]" and is skipped.
            $space = $refline.IndexOf(' ')
            $branch = if ($space -lt 0) { $refline } else { $refline.Substring(0, $space) }
            $track = if ($space -lt 0) { $refline } else { $refline.Substring($space + 1) }
            if ($track -cne '[gone]') { continue }
            if ($branch -eq '') { continue }
            if ($branch -ceq $current) { continue }
            # `grep -Fxq`: a WHOLE-LINE literal match, ordinal.
            if ($worktreeBranches.Contains($branch)) { continue }
            $del = Invoke-ProjGit -Directory $Directory -Arguments @('branch', '-D', '--', $branch)
            if ($del.Ok) { Write-FmOut "${Label}: pruned $branch" }
        }
    }

    # --- per-project sync ------------------------------------------------------

    function Sync-Project {
        param([string]$Proj)

        # project_label: a clone inside this home's projects dir (or under a
        # literal relative "projects/") is named by its basename; anything else
        # prints the path as resolved.
        $label = $Proj
        if ($Proj.StartsWith($projectsDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
            $Proj.StartsWith($projectsDir + '/', [System.StringComparison]::Ordinal) -or
            $Proj.StartsWith('projects/', [System.StringComparison]::Ordinal) -or
            $Proj.StartsWith('projects\', [System.StringComparison]::Ordinal)) {
            $label = Get-Basename $Proj
        }

        if (-not (Test-ProjDirectory $Proj)) {
            Write-FmOut "${label}: skipped: not a directory"
            return
        }
        $inTree = Invoke-ProjGit -Directory $Proj -Arguments @('rev-parse', '--is-inside-work-tree')
        if (-not $inTree.Ok) {
            Write-FmOut "${label}: skipped: not a git repo"
            return
        }

        $modeResult = Invoke-FmScript -Name 'fm-project-mode' -Arguments @($label) -BinDir $binDir
        $modeLine = if ($modeResult.Ok) { Get-CmdOut $modeResult.StdOut } else { 'no-mistakes off' }
        $space = $modeLine.IndexOf(' ')
        $mode = if ($space -lt 0) { $modeLine } else { $modeLine.Substring(0, $space) }
        if ($mode -ceq 'local-only') {
            Write-FmOut "${label}: skipped: local-only project"
            return
        }
        $remote = Invoke-ProjGit -Directory $Proj -Arguments @('remote', 'get-url', 'origin')
        if (-not $remote.Ok) {
            Write-FmOut "${label}: skipped: no origin remote"
            return
        }

        $fetch = Invoke-FetchWithPackedRefsLockGuard -Directory $Proj -Label $label
        if (-not $fetch.Ok) {
            $reason = 'fetch failed'
            if ($fetch.Output -ne '') { $reason = $reason + ': ' + (Get-FmFfFirstLine -Text $fetch.Output) }
            Write-FmOut "${label}: skipped: $reason"
            return
        }

        Invoke-PruneGoneBranch -Directory $Proj -Label $label

        $default = Get-FmFfDefaultBranch -Directory $Proj
        if ([string]::IsNullOrEmpty($default)) {
            Write-FmOut "${label}: skipped: cannot determine default branch"
            return
        }
        $base = "origin/$default"
        $baseExists = Invoke-ProjGit -Directory $Proj -Arguments @(
            'rev-parse', '--verify', '--quiet', "$base^{commit}")
        if (-not $baseExists.Ok) {
            Write-FmOut "${label}: skipped: $base does not exist"
            return
        }

        $headResult = Invoke-ProjGit -Directory $Proj -Arguments @('symbolic-ref', '--short', 'HEAD')
        $cur = ''
        if ($headResult.Ok) { $cur = Get-CmdOut $headResult.StdOut }
        $status = Invoke-ProjGit -Directory $Proj -Arguments @('status', '--porcelain')
        $dirty = 'no'
        if (-not [string]::IsNullOrEmpty($status.StdOut) -and (@($status.StdOut -split "`n")[0]) -ne '') {
            $dirty = 'yes'
        }
        $recovered = 'no'

        # True when some worktree of the clone has $default checked out (so we
        # cannot attach to it here). The current worktree is detached when this is
        # consulted, so any match is necessarily another worktree.
        $defaultCheckedOutElsewhere = {
            return ((Get-WorktreeBranch -Directory $Proj).Contains($default))
        }
        $localDefaultSafeForRecovery = {
            $exists = Invoke-ProjGit -Directory $Proj -Arguments @(
                'rev-parse', '--verify', '--quiet', "$default^{commit}")
            if (-not $exists.Ok) { return $true }
            return (Invoke-ProjGit -Directory $Proj -Arguments @(
                    'merge-base', '--is-ancestor', $default, $base)).Ok
        }

        # Human-readable name for the unsafe state the clone is in, used in the
        # STUCK warning: the most informative description the evidence supports.
        $stuckState = {
            $s = ''
            if ($cur -ne '') {
                $s = "branch $cur"
            } elseif ($dirty -ceq 'yes') {
                $s = 'detached HEAD'
            } elseif (-not (Invoke-ProjGit -Directory $Proj -Arguments @(
                        'merge-base', '--is-ancestor', 'HEAD', $base)).Ok) {
                $s = 'detached HEAD with unique commits'
            } elseif (& $defaultCheckedOutElsewhere) {
                $s = "detached HEAD ($default checked out in another worktree)"
            } elseif (-not (& $localDefaultSafeForRecovery)) {
                $s = "detached HEAD (local $default diverged from $base)"
            } else {
                $s = 'detached HEAD'
            }
            if ($dirty -cne 'no') { $s = "$s with uncommitted changes" }
            return $s
        }

        # Loud, quantified report for a clone we deliberately leave untouched.
        # Includes how far behind origin/<default> it is, so a chronically-stuck
        # clone is visibly distinct from a benign one-off skip.
        $reportStuck = {
            param([string]$State)
            $count = Invoke-ProjGit -Directory $Proj -Arguments @('rev-list', '--count', "HEAD..$base")
            $behind = if ($count.Ok) { Get-CmdOut $count.StdOut } else { '?' }
            Write-FmOut "${label}: STUCK: on $State, $behind commits behind $base - needs attention"
        }

        if ($cur -cne $default) {
            # Off the default branch. Auto-recover only the one unambiguously safe
            # drift: a clean, detached HEAD that holds no unique commits (it is an
            # ancestor of origin/<default>) and whose <default> branch is free to
            # check out here. Re-attaching to an already-published commit strands
            # nothing, and the fast-forward path below then catches the clone up.
            # Anything else - a non-default named branch, a detached HEAD with
            # unique commits, a dirty tree, or <default> already checked out
            # elsewhere - may hold real work, so it is reported loudly and left
            # untouched.
            $safe = ($cur -eq '') -and ($dirty -ceq 'no') -and
                (Invoke-ProjGit -Directory $Proj -Arguments @('merge-base', '--is-ancestor', 'HEAD', $base)).Ok -and
                (-not (& $defaultCheckedOutElsewhere)) -and (& $localDefaultSafeForRecovery)
            if ($safe) {
                $checkout = Invoke-ProjGit -Directory $Proj -Arguments @('checkout', '--quiet', $default)
                if (-not $checkout.Ok) {
                    & $reportStuck (& $stuckState)
                    return
                }
                $recovered = 'yes'
                $cur = $default
            } else {
                & $reportStuck (& $stuckState)
                return
            }
        } elseif ($dirty -ceq 'yes') {
            # On the default branch but with uncommitted changes we must not disturb.
            & $reportStuck (& $stuckState)
            return
        }

        $localExists = Invoke-ProjGit -Directory $Proj -Arguments @(
            'rev-parse', '--verify', '--quiet', "$default^{commit}")
        if (-not $localExists.Ok) {
            Write-FmOut "${label}: skipped: local $default does not exist"
            return
        }

        $localRevResult = Invoke-ProjGit -Directory $Proj -Arguments @('rev-parse', $default)
        if (-not $localRevResult.Ok) {
            Write-FmOut "${label}: skipped: cannot read local $default"
            return
        }
        $localRev = Get-CmdOut $localRevResult.StdOut
        $remoteRevResult = Invoke-ProjGit -Directory $Proj -Arguments @('rev-parse', $base)
        if (-not $remoteRevResult.Ok) {
            Write-FmOut "${label}: skipped: cannot read $base"
            return
        }
        $remoteRev = Get-CmdOut $remoteRevResult.StdOut
        if ($localRev -ceq $remoteRev) {
            if ($recovered -ceq 'yes') {
                Write-FmOut "${label}: recovered: re-attached $default (already current)"
            } else {
                Write-FmOut "${label}: already current"
            }
            return
        }
        if (-not (Invoke-ProjGit -Directory $Proj -Arguments @(
                    'merge-base', '--is-ancestor', $default, $base)).Ok) {
            & $reportStuck "diverged $default"
            return
        }

        $beforeResult = Invoke-ProjGit -Directory $Proj -Arguments @('rev-parse', '--short', $default)
        if (-not $beforeResult.Ok) {
            Write-FmOut "${label}: skipped: cannot read local $default"
            return
        }
        $before = Get-CmdOut $beforeResult.StdOut

        $merge = Invoke-ProjGit -Directory $Proj -Arguments @('merge', '--ff-only', $base)
        if (-not $merge.Ok) {
            $reason = 'fast-forward failed'
            $mergeOutput = Get-CombinedOut $merge
            if ($mergeOutput -ne '') { $reason = $reason + ': ' + (Get-FmFfFirstLine -Text $mergeOutput) }
            Write-FmOut "${label}: skipped: $reason"
            return
        }
        $afterResult = Invoke-ProjGit -Directory $Proj -Arguments @('rev-parse', '--short', $default)
        if (-not $afterResult.Ok) {
            Write-FmOut "${label}: skipped: fast-forward completed but cannot read local $default"
            return
        }
        $after = Get-CmdOut $afterResult.StdOut
        if ($recovered -ceq 'yes') {
            Write-FmOut "${label}: recovered: re-attached $default, synced $before..$after"
        } else {
            Write-FmOut "${label}: synced $before..$after"
        }
    }

    # --- argument resolution ---------------------------------------------------
    #
    # resolve_project_arg: accept a path (used as-is when it already exists) or a
    # bare/"projects/<name>" project name, resolved against this home's projects
    # dir. Falls back to the original argument unresolved so a genuinely bad path
    # still hits Sync-Project's existing "not a directory" skip.
    function Resolve-ProjectArg {
        param([string]$Arg)
        if ($Arg.StartsWith('projects/', [System.StringComparison]::Ordinal)) {
            $candidate = Join-Path $projectsDir $Arg.Substring('projects/'.Length)
            if (Test-ProjDirectory $candidate) { return $candidate }
            return $Arg
        }
        # The bash pattern is `*/*`, i.e. a FORWARD slash only. A Windows-spelled
        # path with backslashes therefore falls to the bare-name arm, where the
        # second `[ -d "$arg" ]` still finds it - the same answer by a different
        # route, which is why the pattern is not "improved" here.
        if ($Arg.Contains('/')) {
            if (Test-ProjDirectory $Arg) { return $Arg }
            return $Arg
        }
        $candidate = Join-Path $projectsDir $Arg
        if (Test-ProjDirectory $candidate) { return $candidate }
        if (Test-ProjDirectory $Arg) { return $Arg }
        return $Arg
    }

    if ($fmArgv.Count -eq 1) {
        Sync-Project (Resolve-ProjectArg ([string]$fmArgv[0]))
        Exit-FmScript 0
    }

    $projectsNative = ConvertTo-FmNativePath $projectsDir
    if (-not (Test-Path -LiteralPath $projectsNative -PathType Container)) { Exit-FmScript 0 }

    # `for proj in "$PROJECTS"/*`: dot-prefixed entries are not matched by a bash
    # glob, non-directories are skipped, and the order is the shell's sort. Ordinal
    # sorting is the LC_ALL=C twin, and is chosen over the .NET default (which is
    # culture-aware and would order differently from the oracle).
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($projectsNative)) {
        $leaf = [System.IO.Path]::GetFileName($e)
        if ($leaf.StartsWith('.')) { continue }
        $entries.Add($e)
    }
    $entries.Sort([System.StringComparer]::Ordinal)
    foreach ($proj in $entries) {
        if (-not (Test-Path -LiteralPath $proj -PathType Container)) { continue }
        Sync-Project $proj
    }
    Exit-FmScript 0
}
