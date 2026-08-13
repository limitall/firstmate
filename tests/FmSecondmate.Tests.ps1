#requires -Version 7.0
# Pester tests for Private/FmSecondmate.ps1 - retiring a secondmate home.
#
# This area deletes a whole firstmate installation and edits the fleet's only
# routing record, so every test here is about a REFUSAL or about an ordering.
# The two properties that matter most, and that a reader should be able to find
# by name below:
#
#   1. A refusal changes NOTHING. Not the home, not the registry row, not the
#      state records. Each refusal test asserts all three survive, because the
#      failure mode this area exists to prevent is a half-performed retirement.
#   2. The routing row goes LAST. While the row is there the home is findable,
#      so it may never be removed at or before a step that can still refuse.
#
# Homes, locks and backlogs are REAL on disk - the gate's whole job is to read
# what is actually there, and a mocked filesystem would only prove the mock
# agrees with itself. treehouse is mocked: it mutates shared machine state.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes and repos. -WhatIf on a fixture would leave the suite asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # A firstmate home in the shape fm-setup.ps1 leaves behind.
    function New-TestHome {
        param([Parameter(Mandatory)][string]$Path, [string]$Backlog = '')
        foreach ($leaf in @('state', 'data', 'config', 'projects')) {
            New-Item -ItemType Directory -Path (Join-Path $Path $leaf) -Force | Out-Null
        }
        $text = if ($Backlog) { $Backlog } else { "# Backlog`n`n## In flight`n`n## Queued`n`n## Done`n" }
        [System.IO.File]::WriteAllText((Join-Path $Path 'data' 'backlog.md'), $text)
        $Path
    }

    function New-TestLock {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$HolderPid)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Path 'pid'), "$HolderPid`n")
        $Path
    }

    # A pid that is provably NOT running. 0 is not a safe choice: on Linux it
    # resolves to the kernel scheduler and reads as alive.
    function Get-DeadProcessId {
        $candidate = 999999
        while (Get-Process -Id $candidate -ErrorAction SilentlyContinue) { $candidate-- }
        $candidate
    }

    function New-TestMeta {
        param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][string]$Id, [hashtable]$Field = @{})
        $lines = foreach ($key in ($Field.Keys | Sort-Object)) { "$key=$($Field[$key])" }
        [System.IO.File]::WriteAllText((Join-Path $StateDir "$Id.meta"), (@($lines) -join "`n") + "`n")
    }

    $script:Registry = @(
        '# Secondmates'
        ''
        '- sm-demo - home `C:\homes\sm-demo` - scope: the demo lane'
        '  continues on a wrapped line'
        '- sm-demo-2 - home `C:\homes\sm-demo-2` - scope: a second lane'
        '- other - home `C:\homes\other` - scope: unrelated'
        ''
    ) -join "`n"
}

# =============================================================================
# Reading the home
# =============================================================================

Describe 'Test-FmSecondmateHomeShape' {
    It 'recognises a home by its layout, and nothing else by anything' {
        $smHome = New-TestHome -Path (Join-Path $TestDrive 'shaped')
        Test-FmSecondmateHomeShape -HomePath $smHome | Should -BeTrue

        $bare = Join-Path $TestDrive 'bare'
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        Test-FmSecondmateHomeShape -HomePath $bare | Should -BeFalse
        Test-FmSecondmateHomeShape -HomePath (Join-Path $TestDrive 'absent') | Should -BeFalse
        Test-FmSecondmateHomeShape -HomePath '' | Should -BeFalse
    }

}

Describe 'Get-FmSecondmateDescendantTask' {
    # Test names avoid angle brackets on purpose: Pester reads `<name>` in an It
    # title as a -ForEach data placeholder and resolves it as a variable, so a
    # descriptive `state/<id>.meta` here fails the test with "the variable $id
    # cannot be retrieved" under strict mode.
    It 'reports one record per meta file in that home, with what a release would need' {
        $smHome = New-TestHome -Path (Join-Path $TestDrive 'descendants')
        $state = Join-Path $smHome 'state'
        New-TestMeta -StateDir $state -Id 'child-b' -Field @{
            worktree = 'C:\wt\b'; project = 'C:\proj'; treehouse_lease_id = 'lease-b'
        }
        New-TestMeta -StateDir $state -Id 'child-a' -Field @{ worktree = 'C:\wt\a' }

        $found = @(Get-FmSecondmateDescendantTask -HomePath $smHome)
        $found.Count | Should -Be 2
        $found[0].Id | Should -Be 'child-a'
        $found[1].LeaseId | Should -Be 'lease-b'
        $found[1].Project | Should -Be 'C:\proj'
    }

    It 'reports nothing for a home with no state directory, rather than failing' {
        @(Get-FmSecondmateDescendantTask -HomePath (Join-Path $TestDrive 'nowhere')).Count | Should -Be 0
        @(Get-FmSecondmateDescendantTask -HomePath '').Count | Should -Be 0
    }
}

Describe 'Get-FmSecondmateLiveLock' {
    BeforeEach { $script:smHome = New-TestHome -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))) }

    It 'finds a directory lock a LIVE process holds, whatever it is called' {
        # Enumerated by shape - any directory with a pid child - so a lock species
        # this port grows later is covered the day it exists.
        $null = New-TestLock -Path (Join-Path $script:smHome 'state' '.some-future.lock') -HolderPid "$PID"
        $live = @(Get-FmSecondmateLiveLock -HomePath $script:smHome)
        $live.Count | Should -Be 1
        $live[0].Kind | Should -Be 'task'
        $live[0].ProcessId | Should -Be $PID
    }

    It 'does NOT report a lock whose holder is gone: a dead holder is not a live descendant' {
        $null = New-TestLock -Path (Join-Path $script:smHome 'state' '.control-x.lock') -HolderPid "$(Get-DeadProcessId)"
        @(Get-FmSecondmateLiveLock -HomePath $script:smHome).Count | Should -Be 0
    }

    It 'ignores a directory that is not a lock at all' {
        New-Item -ItemType Directory -Path (Join-Path $script:smHome 'state' 'procevent') -Force | Out-Null
        @(Get-FmSecondmateLiveLock -HomePath $script:smHome).Count | Should -Be 0
    }

    It 'reports the session lock when a live harness holds that home' {
        # state/.lock is a FILE holding a harness pid, so it is asked separately
        # from the directory locks. A held one means a live firstmate session is
        # operating this home right now - the strongest live-descendant signal
        # there is, and the one a caller must never override.
        Mock Test-FmHarnessProcess { $true }
        [System.IO.File]::WriteAllText((Join-Path $script:smHome 'state' '.lock'), "$PID`n")
        $live = @(Get-FmSecondmateLiveLock -HomePath $script:smHome)
        $live.Count | Should -Be 1
        $live[0].Kind | Should -Be 'session'
    }
}

Describe 'Get-FmSecondmateInFlightTask' {
    It 'reads THAT home''s own backlog, in flight only' {
        $smHome = New-TestHome -Path (Join-Path $TestDrive 'backlogged') -Backlog @"
# Backlog

## In flight
- [ ] sm-live - work under way

## Queued
- [ ] sm-later - not started

## Done
"@
        $answer = Get-FmSecondmateInFlightTask -HomePath $smHome
        $answer.Readable | Should -BeTrue
        @($answer.Task).Count | Should -Be 1
        $answer.Task[0].Id | Should -Be 'sm-live'
    }

    It 'answers about that home even when TASKS_AXI_FILE points somewhere else' {
        # The hazard in one test: TASKS_AXI_FILE is process-wide, so without
        # -IgnoreEnvironment this question about a secondmate's home would be
        # answered from the operator's override - most likely the LAUNCHING
        # home's backlog, the one file this check must not consult. Answering
        # "no work under way" off the wrong file deletes a busy home.
        $prior = $env:TASKS_AXI_FILE
        try {
            $other = New-TestHome -Path (Join-Path $TestDrive 'other-home') -Backlog @"
# Backlog

## In flight
- [ ] wrong-home - this must never be reported

## Queued

## Done
"@
            $env:TASKS_AXI_FILE = Join-Path $other 'data' 'backlog.md'
            $smHome = New-TestHome -Path (Join-Path $TestDrive 'quiet-home')
            @((Get-FmSecondmateInFlightTask -HomePath $smHome).Task).Count | Should -Be 0
        } finally {
            if ($null -eq $prior) {
                Remove-Item -LiteralPath 'env:TASKS_AXI_FILE' -ErrorAction SilentlyContinue
            } else { $env:TASKS_AXI_FILE = $prior }
        }
    }

    It 'reports a home with no backlog file as readable with nothing in flight' {
        $smHome = Join-Path $TestDrive 'no-backlog'
        New-Item -ItemType Directory -Path (Join-Path $smHome 'state') -Force | Out-Null
        $answer = Get-FmSecondmateInFlightTask -HomePath $smHome
        $answer.Readable | Should -BeTrue -Because 'no backlog is not the same as an unreadable one'
        @($answer.Task).Count | Should -Be 0
    }

    It 'separates "could not read it" from "nothing in flight"' {
        # Opposite verdicts: no items means the home is idle, an unreadable file
        # proves nothing at all. Collapsing them would delete a home on a failed
        # read. A malformed .tasks.toml is the case where the backlog cannot even
        # be located, let alone parsed.
        $smHome = New-TestHome -Path (Join-Path $TestDrive 'broken-backlog')
        [System.IO.File]::WriteAllText((Join-Path $smHome '.tasks.toml'), "nonsense`n")
        $answer = Get-FmSecondmateInFlightTask -HomePath $smHome
        $answer.Readable | Should -BeFalse
        $answer.Detail | Should -Not -BeNullOrEmpty
    }
}

# =============================================================================
# The identity gate - the refusals no authority overrides
# =============================================================================

Describe 'Test-FmSecondmateHomeSafety' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:launching = New-TestHome -Path (Join-Path $script:root 'home')
        $script:sub = New-TestHome -Path (Join-Path $script:root 'sub')
    }

    It 'allows an ordinary separate home' {
        (Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath $script:sub -FirstmateHome $script:launching).Verdict |
            Should -Be 'allow'
    }

    It 'REFUSES a meta that records no home at all' {
        $verdict = Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath '' -FirstmateHome $script:launching
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*records no home*'
    }

    It 'REFUSES the launching home, the checkout, the worktree and the project clone by name' {
        # `home=` DEFAULTS to the project directory when a secondmate is spawned
        # without -LabelHome, so this is a shape that reaches here in practice.
        foreach ($case in @(
                @{ Path = $script:launching; Like = '*the launching firstmate home*' }
                @{ Path = (Get-FmRoot); Like = '*this checkout*' }
                @{ Path = (Join-Path $script:root 'wt'); Like = '*own worktree*' }
                @{ Path = (Join-Path $script:root 'proj'); Like = '*project clone*' })) {
            $verdict = Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath $case.Path `
                -FirstmateHome $script:launching -Worktree (Join-Path $script:root 'wt') `
                -Project (Join-Path $script:root 'proj')
            $verdict.Verdict | Should -Be 'refuse' -Because "$($case.Path) is not a retirable home"
            ($verdict.Message -join ' ') | Should -BeLike $case.Like
        }
    }

    It 'REFUSES a home that CONTAINS the launching home, which equality alone would miss' {
        $verdict = Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath $script:root -FirstmateHome $script:launching
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*CONTAINS*'
    }

    It 'REFUSES a path that is not shaped like a firstmate home' {
        $bare = Join-Path $script:root 'not-a-home'
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        $verdict = Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath $bare -FirstmateHome $script:launching
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*holds no state/, config/, data/ or projects/*'
    }

    It 'reports an already-absent home as gone, so an interrupted retirement can be finished' {
        (Test-FmSecondmateHomeSafety -TaskId 'sm' -HomePath (Join-Path $script:root 'vanished') `
                -FirstmateHome $script:launching).Verdict | Should -Be 'gone'
    }
}

# =============================================================================
# The retirement gate
# =============================================================================

Describe 'Test-FmSecondmateRetirementSafety' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:launching = New-TestHome -Path (Join-Path $script:root 'home')
        $script:sub = New-TestHome -Path (Join-Path $script:root 'sub')
        $script:gate = @{ TaskId = 'sm'; HomePath = $script:sub; FirstmateHome = $script:launching }
    }

    It 'allows an idle, clean home' {
        (Test-FmSecondmateRetirementSafety @script:gate).Verdict | Should -Be 'allow'
    }

    It 'REFUSES a live descendant lock, and -Force does NOT override it' {
        $null = New-TestLock -Path (Join-Path $script:sub 'state' '.control-child.lock') -HolderPid "$PID"
        foreach ($forced in @($false, $true)) {
            $verdict = Test-FmSecondmateRetirementSafety @script:gate -Force:$forced
            $verdict.Verdict | Should -Be 'refuse' -Because 'force authorizes discarding work, never removing a home a live process is using'
            ($verdict.Message -join ' ') | Should -BeLike '*live descendant holding a lock*'
        }
    }

    It 'names WHICH lock is live, so the refusal is actionable' {
        $lock = New-TestLock -Path (Join-Path $script:sub 'state' '.control-child.lock') -HolderPid "$PID"
        ((Test-FmSecondmateRetirementSafety @script:gate).Message -join ' ') | Should -BeLike "*$lock*"
    }

    It 'REFUSES work under way in ITS OWN state records, naming each one' {
        New-TestMeta -StateDir (Join-Path $script:sub 'state') -Id 'child-1' -Field @{ kind = 'ship' }
        $verdict = Test-FmSecondmateRetirementSafety @script:gate
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*task record child-1*'
    }

    It 'REFUSES work under way in ITS OWN backlog, naming the item' {
        [System.IO.File]::WriteAllText((Join-Path $script:sub 'data' 'backlog.md'), @"
# Backlog

## In flight
- [ ] sm-live - the demo lane refactor

## Queued

## Done
"@)
        $verdict = Test-FmSecondmateRetirementSafety @script:gate
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*backlog item in flight: sm-live*'
    }

    It 'does NOT read the LAUNCHING home''s records when deciding about the secondmate' {
        # The exact confusion the brief names: work in the home doing the
        # retiring says nothing about whether the home being retired is busy.
        New-TestMeta -StateDir (Join-Path $script:launching 'state') -Id 'sm' -Field @{ kind = 'secondmate' }
        [System.IO.File]::WriteAllText((Join-Path $script:launching 'data' 'backlog.md'), @"
# Backlog

## In flight
- [ ] launching-work - busy over here

## Queued

## Done
"@)
        (Test-FmSecondmateRetirementSafety @script:gate).Verdict | Should -Be 'allow'
    }

    It 'REFUSES a backlog it cannot read, rather than reading it as idle' {
        [System.IO.File]::WriteAllText((Join-Path $script:sub '.tasks.toml'), "nonsense`n")
        $verdict = Test-FmSecondmateRetirementSafety @script:gate
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*could not be read*'
    }

    It 'lets -Force override work under way, which is a discard the captain approved' {
        New-TestMeta -StateDir (Join-Path $script:sub 'state') -Id 'child-1' -Field @{ kind = 'ship' }
        (Test-FmSecondmateRetirementSafety @script:gate -Force).Verdict | Should -Be 'allow'
    }

    It 'REFUSES unlanded work in a project clone of that home, by the ORDINARY rules' {
        $clone = Join-Path $script:sub 'projects' 'proj'
        New-Item -ItemType Directory -Path $clone -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $clone)
        $null = Invoke-FmGit -Directory $clone -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $clone -Arguments @('config', 'user.name', 'Test')
        Set-Content -LiteralPath (Join-Path $clone 'seed.txt') -Value 'seed' -NoNewline
        $null = Invoke-FmGit -Directory $clone -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $clone -Arguments @('commit', '-q', '-m', 'seed')
        Set-Content -LiteralPath (Join-Path $clone 'work.txt') -Value 'unlanded' -NoNewline

        $verdict = Test-FmSecondmateRetirementSafety @script:gate
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*project clone proj*'
        ($verdict.Message -join ' ') | Should -BeLike '*uncommitted changes*'

        (Test-FmSecondmateRetirementSafety @script:gate -Force).Verdict | Should -Be 'allow'
    }

    It 'runs the landed-work test over the secondmate''s OWN worktree too' {
        # The kind carve-out inside Test-FmTeardownWorktreeSafety is a deferral to
        # this gate, so the gate has to call it back with the ordinary kind. If it
        # ever passed -Kind secondmate the test would defer to itself and every
        # dirty worktree would pass.
        $wt = Join-Path $script:root 'wt'
        New-Item -ItemType Directory -Path $wt -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $wt)
        Set-Content -LiteralPath (Join-Path $wt 'dirty.txt') -Value 'x' -NoNewline

        $verdict = Test-FmSecondmateRetirementSafety @script:gate -Worktree $wt -Project $wt
        $verdict.Verdict | Should -Be 'refuse'
        ($verdict.Message -join ' ') | Should -BeLike '*own worktree*'
    }

    It 'still refuses a live lock when the home is otherwise perfectly idle and clean' {
        # Ordering: liveness is proved BEFORE the discard checks, so the strongest
        # refusal is the one an operator sees.
        $null = New-TestLock -Path (Join-Path $script:sub 'state' '.task-set.lock') -HolderPid "$PID"
        New-TestMeta -StateDir (Join-Path $script:sub 'state') -Id 'child-1' -Field @{ kind = 'ship' }
        ((Test-FmSecondmateRetirementSafety @script:gate).Message -join ' ') |
            Should -BeLike '*live descendant*'
    }
}

# =============================================================================
# Releasing what the home owns
# =============================================================================

Describe 'Remove-FmSecondmateDescendantLease' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:sub = New-TestHome -Path (Join-Path $script:root 'sub')
        $script:wt = Join-Path $script:root 'child-wt'
        New-Item -ItemType Directory -Path $script:wt -Force | Out-Null
        New-TestMeta -StateDir (Join-Path $script:sub 'state') -Id 'child-1' -Field @{
            worktree = $script:wt; project = $script:root; treehouse_lease_id = 'lease-child'
        }
        Mock Test-FmTeardownTreehouseAvailable { $true }
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'returned'; Detail = '' } }
    }

    It 'returns each descendant worktree CONDITIONALLY on its own recorded lease' {
        $result = Remove-FmSecondmateDescendantLease -HomePath $script:sub -TaskId 'sm' -Confirm:$false
        $result.Outcome | Should -Be 'returned'
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 1 -ParameterFilter { $LeaseId -eq 'lease-child' }
    }

    It 'reports a FAILED return rather than swallowing it, so the caller can refuse' {
        # The lease record lives in the meta that is about to go with the home, so
        # a return that did not happen has to stop the removal - otherwise the
        # pool holds a lease nothing anywhere names.
        Mock Invoke-FmTeardownWorktreeReturn { [pscustomobject]@{ Outcome = 'lock-refused'; Detail = 'lock persisted' } }
        $result = Remove-FmSecondmateDescendantLease -HomePath $script:sub -TaskId 'sm' -Confirm:$false
        $result.Outcome | Should -Be 'failed'
        ($result.Failed -join ' ') | Should -BeLike '*child-1*lock persisted*'
    }

    It 'refuses to start when treehouse is absent, rather than orphaning some of them' {
        Mock Test-FmTeardownTreehouseAvailable { $false }
        $result = Remove-FmSecondmateDescendantLease -HomePath $script:sub -TaskId 'sm' -Confirm:$false
        $result.Outcome | Should -Be 'unavailable'
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 0
    }

    It 'has nothing to do for a home whose tasks hold no worktree on disk' {
        Remove-Item -LiteralPath $script:wt -Recurse -Force
        (Remove-FmSecondmateDescendantLease -HomePath $script:sub -TaskId 'sm' -Confirm:$false).Outcome |
            Should -Be 'nothing-to-do'
        Should -Invoke Invoke-FmTeardownWorktreeReturn -Times 0
    }
}

# =============================================================================
# Removing the home
# =============================================================================

Describe 'Remove-FmSecondmateHome' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        $script:launching = New-TestHome -Path (Join-Path $script:root 'home')
        $script:sub = New-TestHome -Path (Join-Path $script:root 'sub')
    }

    It 'removes the home and says so' {
        $result = Remove-FmSecondmateHome -TaskId 'sm' -HomePath $script:sub -FirstmateHome $script:launching -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.Outcome | Should -Be 'removed'
        Test-Path -LiteralPath $script:sub | Should -BeFalse
        Test-Path -LiteralPath $script:launching | Should -BeTrue
    }

    It 're-proves identity itself, so a reordering upstream cannot make it delete the wrong tree' {
        $result = Remove-FmSecondmateHome -TaskId 'sm' -HomePath $script:launching -FirstmateHome $script:launching -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.Outcome | Should -Be 'refused'
        Test-Path -LiteralPath $script:launching | Should -BeTrue
    }

    It 'treats an already-absent home as done, so a rerun finishes the job' {
        $result = Remove-FmSecondmateHome -TaskId 'sm' -HomePath (Join-Path $script:root 'vanished') `
            -FirstmateHome $script:launching -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.Outcome | Should -Be 'already-gone'
    }

    It 'reports a PARTIAL removal as a failure and names what is left' -Skip:(-not $IsWindows) {
        # Windows refuses a delete while anything holds a handle, so "some of it
        # went" is exactly the case where the caller must keep the routing row and
        # the state records that still point at what remains.
        $held = Join-Path $script:sub 'data' 'open.txt'
        [System.IO.File]::WriteAllText($held, 'x')
        $stream = [System.IO.File]::Open($held, 'Open', 'Read', [System.IO.FileShare]::None)
        try {
            $result = Remove-FmSecondmateHome -TaskId 'sm' -HomePath $script:sub `
                -FirstmateHome $script:launching -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Outcome | Should -Be 'failed'
            $result.Detail | Should -BeLike '*not fully removed*'
        } finally {
            $stream.Dispose()
        }
    }
}

# =============================================================================
# The routing record
# =============================================================================

Describe 'Remove-FmSecondmateRegistryRow' {
    BeforeEach {
        $script:data = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:data -Force | Out-Null
        $script:path = Join-Path $script:data 'secondmates.md'
        [System.IO.File]::WriteAllText($script:path, $script:Registry)
    }

    It 'removes exactly this secondmate''s row, wrapped continuation and all' {
        $result = Remove-FmSecondmateRegistryRow -DataDir $script:data -TaskId 'sm-demo' -Confirm:$false
        $result.Outcome | Should -Be 'removed'
        $text = [System.IO.File]::ReadAllText($script:path)
        $text | Should -Not -BeLike '*- sm-demo -*'
        $text | Should -Not -BeLike '*continues on a wrapped line*'
        $text | Should -BeLike '*- sm-demo-2 -*'
        $text | Should -BeLike '*- other -*'
        $text | Should -BeLike '*# Secondmates*'
    }

    It 'does not mistake a longer id for this one' {
        $null = Remove-FmSecondmateRegistryRow -DataDir $script:data -TaskId 'sm-demo-2' -Confirm:$false
        $text = [System.IO.File]::ReadAllText($script:path)
        $text | Should -BeLike '*- sm-demo -*'
        $text | Should -Not -BeLike '*- sm-demo-2 -*'
    }

    It 'keeps the LF, no-BOM byte contract a Linux firstmate reads' {
        $null = Remove-FmSecondmateRegistryRow -DataDir $script:data -TaskId 'sm-demo' -Confirm:$false
        $bytes = [System.IO.File]::ReadAllBytes($script:path)
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        ($bytes -contains 0x0D) | Should -BeFalse
    }

    It 'returns the removed lines, so a hand-maintained file gets an auditable edit' {
        $result = Remove-FmSecondmateRegistryRow -DataDir $script:data -TaskId 'sm-demo' -Confirm:$false
        @($result.Removed).Count | Should -Be 2
        $result.Removed[0] | Should -BeLike '*sm-demo*'
    }

    It 'reports an absent registry and an id with no row, without writing anything' {
        (Remove-FmSecondmateRegistryRow -DataDir (Join-Path $TestDrive 'no-data') -TaskId 'sm-demo' -Confirm:$false).Outcome |
            Should -Be 'no-registry'
        $before = [System.IO.File]::ReadAllBytes($script:path)
        (Remove-FmSecondmateRegistryRow -DataDir $script:data -TaskId 'never-registered' -Confirm:$false).Outcome |
            Should -Be 'no-row'
        [System.IO.File]::ReadAllBytes($script:path) | Should -Be $before
    }
}
