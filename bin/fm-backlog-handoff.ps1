# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Twin: bin/fm-backlog-handoff.sh
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# Idempotent: re-running converges. Atomic: on any move failure nothing moves.
# See AGENTS.md project management and task lifecycle.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
#
# ---------------------------------------------------------------------------
# WHY THE TWO awk PROGRAMS ARE PORTED IN-PROCESS RATHER THAN CALLED OUT TO
# ---------------------------------------------------------------------------
# Both read the SAME file the move will touch, and both are pure line
# classifiers - no state, no external data. Shelling out to awk once per key
# would cost a child process per key on a host where a fork is ~360ms, for
# logic that is a dozen lines of string work. The regexes below are the awk
# programs' regexes character for character, with `[[:space:]]` spelled as the
# five in-line C-locale whitespace characters rather than .NET `\s` (which also
# matches NBSP and the Unicode space separators, and so would classify a body
# line the bash leaves alone).
#
# ---------------------------------------------------------------------------
# THE VALIDATION IS DELIBERATELY LOCAL, NOT fm-ff-lib's
# ---------------------------------------------------------------------------
# fm-ff-lib.psm1 has a secondmate-home validator with the same SHAPE, and it is
# not the same contract: its reasons are phrased for a sync report ("not a
# seeded secondmate home"), while these name the path the operator must fix
# ("firstmate home <home> is not a seeded secondmate home"). The bash keeps two
# implementations for exactly that reason, and these messages are what an
# operator sees when a handoff refuses, so they are reproduced verbatim here
# rather than approximated by the library's.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

$fmArgv = @($args)
$fmScriptRoot = $PSScriptRoot

Invoke-FmMain -UnexpectedCode 70 {

    # [[:space:]] minus LF: these classify a single line, which never holds one.
    $spaceClass = '[ \t\v\f\r]'

    # `[ -n "$ancestor" ] && [ -n "$path" ] && [ "$ancestor" != "$path" ] &&
    #  case "$path" in "$ancestor"/*)`. Both separators are accepted because
    # this script resolves to native form while a registry record carries POSIX.
    $isAncestorOf = {
        param([string]$Ancestor, [string]$Path)
        if ([string]::IsNullOrEmpty($Ancestor)) { return $false }
        if ([string]::IsNullOrEmpty($Path)) { return $false }
        if ($Ancestor -ceq $Path) { return $false }
        return ($Path.StartsWith($Ancestor + '\', [System.StringComparison]::Ordinal) -or
            $Path.StartsWith($Ancestor + '/', [System.StringComparison]::Ordinal))
    }

    # `[ -d "$path" ] || { echo ...; return 1; }; cd "$path" && pwd -P`
    $resolvedExistingDir = {
        param([string]$Path)
        $resolved = Resolve-FmPhysicalDirectory -Directory $Path
        if ($null -eq $resolved) {
            Write-FmErr "error: firstmate home does not exist or is not a directory: $Path"
            return $null
        }
        return $resolved
    }

    $validateOperationalDirs = {
        param([string]$AbsHome, [string]$AbsActiveHome, [string]$AbsRoot)
        foreach ($name in @('data', 'state', 'config', 'projects')) {
            $dir = Join-Path $AbsHome $name
            # A DANGLING link is rejected first and by name: `-e` follows links,
            # so a link pointing nowhere would otherwise read as absent and fall
            # through to the "not created yet" arm.
            if ((Test-FmSymlink $dir) -and -not (Test-Path -LiteralPath $dir)) {
                Write-FmErr "error: secondmate $name directory must resolve inside the secondmate home: $dir"
                return $false
            }
            $absDir = $null
            if (Test-Path -LiteralPath $dir -PathType Container) {
                $absDir = Resolve-FmPhysicalDirectory -Directory $dir
                if ($null -eq $absDir) {
                    Write-FmErr "error: secondmate $name directory must resolve inside the secondmate home: $dir"
                    return $false
                }
            } elseif (Test-Path -LiteralPath $dir) {
                Write-FmErr "error: secondmate $name path is not a directory: $dir"
                return $false
            } else {
                $absDir = $dir
            }
            if (-not (& $isAncestorOf $AbsHome $absDir)) {
                Write-FmErr "error: secondmate $name directory must resolve inside the secondmate home: $dir"
                return $false
            }
            if (($absDir -ceq $AbsActiveHome) -or (& $isAncestorOf $AbsActiveHome $absDir)) {
                Write-FmErr "error: secondmate $name directory cannot be inside the active firstmate home: $dir"
                return $false
            }
            if (($absDir -ceq $AbsRoot) -or (& $isAncestorOf $AbsRoot $absDir)) {
                Write-FmErr "error: secondmate $name directory cannot be inside the firstmate repo: $dir"
                return $false
            }
        }
        return $true
    }

    # Returns the resolved home, or $null after reporting the specific boundary
    # that failed. Order is load-bearing: "cannot be the active firstmate home"
    # precedes "cannot be inside" it, or an exact match reads as containment.
    $validateSecondmateHome = {
        param([string]$Id, [string]$HomePath, [string]$ActiveHome, [string]$RepoRoot)

        $absHome = & $resolvedExistingDir $HomePath
        if ($null -eq $absHome) { return $null }
        $absActiveHome = & $resolvedExistingDir $ActiveHome
        if ($null -eq $absActiveHome) { return $null }
        $absRoot = & $resolvedExistingDir $RepoRoot
        if ($null -eq $absRoot) { return $null }

        # `[ "$abs_home" = "/" ]`. The POSIX filesystem root has no single
        # Windows spelling, so a drive root is its twin: the same "everything
        # below this is the whole volume" hazard.
        if ($absHome -ceq '/' -or $absHome -match '^[A-Za-z]:[\\/]?$') {
            Write-FmErr "error: secondmate home cannot be the filesystem root: $HomePath"
            return $null
        }
        if ($absHome -ceq $absActiveHome) {
            Write-FmErr "error: secondmate home cannot be the active firstmate home: $HomePath"
            return $null
        }
        if ($absHome -ceq $absRoot) {
            Write-FmErr "error: secondmate home cannot be the firstmate repo: $HomePath"
            return $null
        }
        if (& $isAncestorOf $absActiveHome $absHome) {
            Write-FmErr "error: secondmate home cannot be inside the active firstmate home: $HomePath"
            return $null
        }
        if (& $isAncestorOf $absRoot $absHome) {
            Write-FmErr "error: secondmate home cannot be inside the firstmate repo: $HomePath"
            return $null
        }
        if (& $isAncestorOf $absHome $absActiveHome) {
            Write-FmErr "error: secondmate home cannot be an ancestor of the active firstmate home: $HomePath"
            return $null
        }
        if (& $isAncestorOf $absHome $absRoot) {
            Write-FmErr "error: secondmate home cannot be an ancestor of the firstmate repo: $HomePath"
            return $null
        }
        if (-not (& $validateOperationalDirs $absHome $absActiveHome $absRoot)) { return $null }

        $marker = Join-Path $absHome '.fm-secondmate-home'
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $marker))) {
            Write-FmErr "error: firstmate home $HomePath is not a seeded secondmate home"
            return $null
        }
        # `$(cat ...)` strips trailing newlines and nothing else, so a marker
        # written with CRLF keeps its CR and fails identity in both worlds.
        $markerId = (Get-FmFileText $marker).TrimEnd("`n")
        if ($markerId -cne $Id) {
            $shown = if ($markerId -eq '') { 'unknown' } else { $markerId }
            Write-FmErr "error: firstmate home $HomePath is marked for secondmate $shown, expected $Id"
            return $null
        }
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $absHome 'AGENTS.md')))) {
            Write-FmErr "error: $HomePath is not a firstmate home (missing AGENTS.md)"
            return $null
        }
        if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath (Join-Path $absHome 'bin')) -PathType Container)) {
            Write-FmErr "error: $HomePath is not a firstmate home (missing bin/)"
            return $null
        }
        return $absHome
    }

    $validateBacklogFile = {
        param([string]$Label, [string]$Path)
        $native = ConvertTo-FmNativePath $Path
        if (Test-FmSymlink $native) {
            Write-FmErr "error: $Label must not be a symlink: $Path"
            return $false
        }
        if ((Test-Path -LiteralPath $native) -and -not [System.IO.File]::Exists($native)) {
            Write-FmErr "error: $Label is not a regular file: $Path"
            return $false
        }
        return $true
    }

    # `sub(/^- \[[ x]\] +/, "", rest); sub(/[ \t].*/, "", id)` - the item id is
    # the first whitespace-delimited word after the checkbox, or $null when the
    # line is not an item header at all.
    $itemHeaderId = {
        param([string]$Line)
        if ($Line -cnotmatch '^- \[[ x]\] ') { return $null }
        $rest = $Line -creplace '^- \[[ x]\] +', ''
        $cut = $rest.IndexOfAny([char[]]@(' ', "`t"))
        if ($cut -ge 0) { return $rest.Substring(0, $cut) }
        return $rest
    }

    # Twin of backlog_key_section: the section heading a key's item header lives
    # under, or $null when no header for that key exists. Reads only headings
    # and item headers - never bodies - so it drives the fleet-level
    # classification without touching the block semantics tasks-axi mv owns.
    $backlogKeySection = {
        param([string]$File, [string]$Key)
        $native = ConvertTo-FmNativePath $File
        if (-not [System.IO.File]::Exists($native)) { return $null }
        # BEGIN { section = "## Queued" }: an item above any heading is queued.
        $section = '## Queued'
        foreach ($line in (Get-FmFileLines $native)) {
            if ($line -cmatch "^##$spaceClass+") {
                $section = $line -creplace "^##$spaceClass+", '## '
                $section = $section -creplace "$spaceClass+`$", ''
                continue
            }
            $id = & $itemHeaderId $line
            if ($null -ne $id -and $id -ceq $Key) { return $section }
        }
        return $null
    }

    # Twin of backlog_key_noncanonical_body_lines: the selected item's
    # continuation lines that are indented but NOT by the two spaces tasks-axi
    # requires. Capture stops at the next item header or the next heading.
    $noncanonicalBodyLines = {
        param([string]$File, [string]$Key)
        $out = [System.Collections.Generic.List[string]]::new()
        $native = ConvertTo-FmNativePath $File
        if (-not [System.IO.File]::Exists($native)) { return @($out) }
        $capturing = $false
        foreach ($line in (Get-FmFileLines $native)) {
            $id = & $itemHeaderId $line
            if ($null -ne $id) {
                if ($capturing) { break }
                if ($id -ceq $Key) { $capturing = $true }
                continue
            }
            if (-not $capturing) { continue }
            if ($line -cmatch "^##$spaceClass+") { break }
            if ($line -cmatch "^$spaceClass" -and $line -cnotmatch '^  ' -and $line -cmatch "[^ \t\v\f\r]") {
                $out.Add($line)
            }
        }
        return @($out)
    }

    # --- argv ----------------------------------------------------------------

    if ($fmArgv.Count -lt 2) {
        Write-FmErr 'usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...'
        Exit-FmScript 1
    }
    $id = [string]$fmArgv[0]
    $keys = @($fmArgv[1..($fmArgv.Count - 1)] | ForEach-Object { [string]$_ })

    $ctx = Get-FmContext $fmScriptRoot
    $registry = Join-Path $ctx.Data 'secondmates.md'
    $mainBacklog = Join-Path $ctx.Data 'backlog.md'

    # `secondmate_home`.
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $registry))) {
        Write-FmErr "error: no secondmate registry at $registry"
        Exit-FmScript 1
    }
    $rawHome = Get-FmSecondmateRegistryField -Registry $registry -Id $id -Key 'home'
    if ([string]::IsNullOrEmpty($rawHome)) {
        Write-FmErr "error: secondmate $id has no home in $registry"
        Exit-FmScript 1
    }

    $subHome = & $validateSecondmateHome $id $rawHome $ctx.Home $ctx.Root
    if ($null -eq $subHome) { Exit-FmScript 1 }
    $subBacklog = Join-Path (Join-Path $subHome 'data') 'backlog.md'

    if (-not (& $validateBacklogFile 'main backlog' $mainBacklog)) { Exit-FmScript 1 }
    if (-not (& $validateBacklogFile 'secondmate backlog' $subBacklog)) { Exit-FmScript 1 }

    # --- classify every key before changing anything -------------------------

    $toMove = [System.Collections.Generic.List[string]]::new()
    $already = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $inFlight = [System.Collections.Generic.List[string]]::new()
    $done = [System.Collections.Generic.List[string]]::new()
    $notQueued = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $keys) {
        if ($null -ne (& $backlogKeySection $subBacklog $key)) {
            $already.Add($key)
            continue
        }
        $section = & $backlogKeySection $mainBacklog $key
        if ($null -eq $section) {
            $missing.Add($key)
            continue
        }
        switch -CaseSensitive ($section) {
            '## Queued' { $toMove.Add($key) }
            '## In flight' { $inFlight.Add($key) }
            '## Done' { $done.Add($key) }
            default { $notQueued.Add($key) }
        }
    }

    $failed = $false
    if ($inFlight.Count -gt 0) {
        Write-FmErr "error: refusing to hand off in-flight backlog items: $($inFlight -join ' ')"
        $failed = $true
    }
    if ($done.Count -gt 0) {
        Write-FmErr ("error: refusing to hand off Done (historical) backlog items: $($done -join ' '); " +
            'handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived.')
        $failed = $true
    }
    if ($notQueued.Count -gt 0) {
        Write-FmErr ("error: refusing to hand off non-queued backlog items: $($notQueued -join ' '); " +
            'handoffs move in-scope queued work only.')
        $failed = $true
    }
    if ($missing.Count -gt 0) {
        Write-FmErr "error: no backlog item matched these keys in ${mainBacklog}: $($missing -join ' ')"
        $failed = $true
    }
    if ($failed) {
        Write-FmErr '       nothing was moved.'
        Exit-FmScript 1
    }

    if ($toMove.Count -eq 0) {
        # `${ALREADY[*]:-no keys}`: the fallback cannot be reached from a valid
        # argv (a key that is in neither backlog already exited above), and is
        # kept so the two twins say the same thing if that ever changes.
        $alreadyText = if ($already.Count -gt 0) { $already -join ' ' } else { 'no keys' }
        Write-FmOut "nothing to move: $alreadyText already present in $subBacklog"
        Exit-FmScript 0
    }

    $failed = $false
    foreach ($key in $toMove) {
        foreach ($line in (& $noncanonicalBodyLines $mainBacklog $key)) {
            Write-FmErr "error: refusing to hand off ${key}: non-2-space continuation line: $line"
            $failed = $true
        }
    }
    if ($failed) {
        Write-FmErr '       nothing was moved.'
        Exit-FmScript 1
    }

    if (-not (Test-FmTasksAxiCompatible)) {
        Write-FmErr 'error: tasks-axi with atomic multi-ID mv support (0.2.2+) is required to move backlog items'
        Exit-FmScript 1
    }

    # Seed the destination with firstmate's standard three-section scaffold when
    # it does not exist yet, so the moved item lands under the right section.
    # (Left to create the file itself, tasks-axi mv writes its own `# Backlog`
    # title format, which is not firstmate's home-backlog convention.)
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath (Join-Path $subHome 'data')))
    $subCreated = $false
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $subBacklog))) {
        Set-FmFileText -Path $subBacklog -Text "## In flight`n`n## Queued`n`n## Done`n" -NoNewline
        $subCreated = $true
    }

    # Delegate the move to tasks-axi. Passing the whole in-scope set to one call
    # is a single atomic transaction, so a connected set (blocker + dependents)
    # moves together and, on any failure, neither backlog's content changes -
    # the only cleanup is a scaffold we just created. tasks-axi writes both its
    # success and error output to stdout, so capture it and surface it only on
    # failure.
    $mv = Invoke-FmTool -FilePath 'tasks-axi' -Arguments (
        @('mv') + @($toMove) + @('--file', (ConvertTo-FmNativePath $mainBacklog),
            '--to', (ConvertTo-FmNativePath $subBacklog)))
    if (-not $mv.Ok) {
        if ($subCreated) { [void](Remove-Item -LiteralPath (ConvertTo-FmNativePath $subBacklog) -Force -ErrorAction SilentlyContinue) }
        $mvOut = ($mv.StdOut + $mv.StdErr).TrimEnd("`n")
        if ($mvOut -ne '') { Write-FmErr $mvOut }
        Write-FmErr 'error: tasks-axi mv failed; nothing was moved.'
        Exit-FmScript 1
    }

    Write-FmOut "handed off $($toMove.Count) item(s) to ${id}: $($toMove -join ' ')"
    Write-FmOut "  into $subBacklog"
    if ($already.Count -gt 0) {
        Write-FmOut "  already present (skipped): $($already -join ' ')"
    }
    Exit-FmScript 0
}
