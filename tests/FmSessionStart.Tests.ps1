#requires -Version 7.0
# Pester tests for the startup digest.
#
# The digest is what the captain reads at session start, so what these tests pin
# is its ORDER and its exact section text. The compact backlog rendering
# expectations were produced by running bin/fm-session-start.sh in the reference
# implementation against the same fixture home and are byte-identical to it.

# The seam stubs below declare their owner's full published parameter list and
# then ignore it, which is the point of the stub: a stub that dropped a name
# would make the caller's by-name invocation throw and its catch would read that
# as "no owner", and a stub declaring no parameters at all would swallow the
# arguments into $args unnoticed. PSReviewUnusedParameter is inverted here.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Test seam stubs must declare their owner''s full published parameter list without using it; see the comment above.')]
param()
BeforeAll {
    # The module loader sets these, so the tests must exercise the same rules.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function Reset-TestEnvironment {
        foreach ($name in @(
                'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
                'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TASKS_AXI_COMPATIBLE',
                'FM_SESSION_START_STATUS_TAIL', 'FM_SESSION_START_QUEUED_LIMIT',
                'FM_SESSION_START_STAGE_FILE', 'FM_SESSION_START_OUTPUT_FILE',
                'FM_SESSION_START_TIMEOUT', 'FM_BACKEND')) {
            Set-Item -Path "env:$name" -Value $null
        }
    }

    function New-TestHome {
        param([switch]$Populated)

        Reset-TestEnvironment
        $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'config', 'projects', 'bin')) {
            New-Item -ItemType Directory -Path (Join-Path $home_ $sub) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $home_ 'AGENTS.md'), "fixture`n")
        $env:FM_HOME = $home_
        $env:FM_ROOT_OVERRIDE = $home_
        # The digest must never depend on a real tasks-axi being installed on the
        # host running the tests.
        $env:FM_TASKS_AXI_COMPATIBLE = '0'

        if ($Populated) {
            [System.IO.File]::WriteAllText((Join-Path $home_ 'data' 'backlog.md'),
                "## In flight`n- task-a - doing things`n`n## Queued`n- task-b - later (hold: waiting on captain)`n- task-c - other`n`n## Done`n- task-z - finished`n")
            [System.IO.File]::WriteAllText((Join-Path $home_ 'data' 'projects.md'),
                "- alpha [direct-PR +yolo] - the alpha project (added 2026-01-01)`n")
            [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'task-a.meta'),
                "window=fm-task-a`nproject=alpha`nkind=crewmate`n")
            [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'task-a.status'),
                "working: started`nneeds-decision: which way [key=route]`ndone: finished`n")
            [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'orphan.status'), "blocked: orphan`n")
        }
        $home_
    }

    function Get-SectionIndex {
        param([string[]]$Digest, [string]$Title)
        for ($i = 0; $i -lt $Digest.Count; $i++) {
            if ($Digest[$i] -eq $Title) { return $i }
        }
        return -1
    }
}

Describe 'Get-FmSessionPaths' {
    It 'resolves every path from the same environment contract the bash scripts use' {
        $home_ = New-TestHome
        $paths = Get-FmSessionPaths
        $paths.Home | Should -Be $home_
        $paths.State | Should -Be (Join-Path $home_ 'state')
        $paths.Data | Should -Be (Join-Path $home_ 'data')
        $paths.Config | Should -Be (Join-Path $home_ 'config')
        $paths.CompletionFile | Should -Be (Join-Path $home_ 'state' '.session-start-complete')
    }

    It 'lets an explicit state override win over FM_HOME/state' {
        New-TestHome | Out-Null
        $override = Join-Path $TestDrive 'elsewhere-state'
        $env:FM_STATE_OVERRIDE = $override
        (Get-FmSessionPaths).State | Should -Be $override
    }
}

Describe 'Get-FmSessionCappedLine' {
    It 'leaves a line at or under the cap byte-identical, marker and all' {
        $line = 'needs-decision: pick one [key=route]'
        Get-FmSessionCappedLine -Line $line | Should -Be $line
    }

    It 'cuts a long line to the cap and marks it, so a 865-character status line cannot flood the digest' {
        $capped = Get-FmSessionCappedLine -Line ('x' * 900)
        $capped.Length | Should -Be 220
        $capped | Should -BeLike '*[[]truncated]'
    }
}

Describe 'Format-FmSessionFileOrAbsent' {
    It 'distinguishes an absent file from an empty-but-present one, because absence is meaningful' {
        $home_ = New-TestHome
        $absent = @(Format-FmSessionFileOrAbsent -Path (Join-Path $home_ 'data' 'captain.md') -Label 'data/captain.md')
        $absent[-1] | Should -Be 'ABSENT'

        [System.IO.File]::WriteAllText((Join-Path $home_ 'data' 'captain.md'), '')
        $empty = @(Format-FmSessionFileOrAbsent -Path (Join-Path $home_ 'data' 'captain.md') -Label 'data/captain.md')
        $empty[-1] | Should -Be '(present, empty)'
    }
}

Describe 'Format-FmSessionBacklogManualCompact' {
    It 'renders the compact listing byte-identically to the bash awk original' {
        $home_ = New-TestHome -Populated
        $lines = @(Format-FmSessionBacklogManualCompact -Path (Join-Path $home_ 'data' 'backlog.md') -Reason 'manual backend')
        $lines[0] | Should -Be 'compact backlog listing (manual backend; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to 20; indented task bodies omitted)'
        $lines[1] | Should -Be '## In flight'
        $lines[2] | Should -Be '- task-a - doing things'
        $lines[3] | Should -Be '## Queued'
        $lines[4] | Should -Be '- task-b - later (hold: waiting on captain)'
        $lines[5] | Should -Be '- task-c - other'
        $lines[6] | Should -Be '(shown 1 in-flight, 1 held or blocked queued, 1 of 1 other queued title line(s); 1 done row(s) omitted)'
    }

    It 'never bounds away a held or blocked row, and discloses exactly what it omitted' {
        $home_ = New-TestHome
        $backlog = Join-Path $home_ 'data' 'backlog.md'
        $rows = @('## Queued')
        1..5 | ForEach-Object { $rows += "- plain-$_ - ordinary" }
        $rows += '- gated - later (hold: captain)'
        $rows += '- dependent - blocked-by: plain-1'
        [System.IO.File]::WriteAllText($backlog, (($rows -join "`n") + "`n"))

        $lines = @(Format-FmSessionBacklogManualCompact -Path $backlog -Reason 'manual backend' -QueuedLimit 2)
        $lines | Should -Contain '- gated - later (hold: captain)'
        $lines | Should -Contain '- dependent - blocked-by: plain-1'
        $lines | Should -Contain '- plain-1 - ordinary'
        $lines | Should -Not -Contain '- plain-3 - ordinary'
        $lines | Should -Contain '(shown 0 in-flight, 2 held or blocked queued, 2 of 5 other queued title line(s); 0 done row(s) omitted)'
        $lines | Should -Contain '(3 more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)'
    }

    It 'never prints a done row' {
        $home_ = New-TestHome -Populated
        $lines = @(Format-FmSessionBacklogManualCompact -Path (Join-Path $home_ 'data' 'backlog.md') -Reason 'manual backend')
        $lines | Should -Not -Contain '- task-z - finished'
        $lines | Should -Not -Contain '## Done'
    }
}

Describe 'the digest reads the queue the backlog commands write' {
    # The digest used to join <home>/data/backlog.md for itself while the backlog
    # commands resolved <home>/backlog.md, so a captain could add a work item,
    # be told it landed, and read ABSENT here. One owner now answers both.

    It 'THE REGRESSION: an added item appears in the digest, not ABSENT' {
        $home_ = New-TestHome
        $null = Add-FmBacklogTask -Id 'fmwin-demo' -Title 'Ship the morning brief' `
            -Path (Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml')).Path
        $digest = @(Get-FmSessionStartDigest)
        @($digest | Where-Object { $_ -like '*fmwin-demo - Ship the morning brief*' }).Count |
            Should -Be 1 -Because 'the digest must render the item the backlog command just wrote'
    }

    It 'names a pre-fix root backlog rather than reporting the queue absent over it' {
        $home_ = New-TestHome
        [System.IO.File]::WriteAllText((Get-FmBacklogLegacyPath -HomePath $home_),
            "# Backlog`n`n## Queued`n- [ ] old - the captain's item`n")
        $digest = @(Get-FmSessionStartDigest)
        @($digest | Where-Object { $_ -like 'LEGACY_BACKLOG: *' }).Count | Should -Be 1
        # And it only REPORTS: the digest runs in lock-refused read-only sessions,
        # where no fleet mutation is authorized.
        Test-Path -LiteralPath (Get-FmBacklogLegacyPath -HomePath $home_) | Should -BeTrue
        Test-Path -LiteralPath (Get-FmBacklogPath -HomePath $home_) | Should -BeFalse
    }

    It 'says nothing about a legacy file in a home that never had one' {
        New-TestHome -Populated | Out-Null
        @(Get-FmSessionStartDigest) | Where-Object { $_ -like 'LEGACY_BACKLOG:*' } | Should -BeNullOrEmpty
    }
}

Describe 'Format-FmSessionStatusTail' {
    It 'bounds the tail and labels it as wake-EVENT history with the full log path' {
        $home_ = New-TestHome -Populated
        $status = Join-Path $home_ 'state' 'task-a.status'
        $lines = @(Format-FmSessionStatusTail -Path $status -Tail 2)
        $lines[0] | Should -Be "status tail (last 2 line(s), each capped at 220 characters, wake-EVENT history, not current state; full log: $status):"
        $lines.Count | Should -Be 3
        $lines[1] | Should -Be 'needs-decision: which way [key=route]'
        $lines[2] | Should -Be 'done: finished'
    }
}

Describe 'Get-FmSessionStartDigest' {
    It 'emits the nine stages in the order the captain reads them' {
        New-TestHome -Populated | Out-Null
        $digest = @(Get-FmSessionStartDigest)

        $order = @('LOCK', 'BOOTSTRAP', 'WAKE QUEUE', 'READ-ONCE CONTRACT', 'FLEET STATE', 'NETWORK CHECKS', 'CONTEXT', 'NEXT STEP')
        $previous = -1
        foreach ($title in $order) {
            $index = Get-SectionIndex -Digest $digest -Title $title
            $index | Should -BeGreaterThan $previous -Because "$title must come after the section before it"
            $previous = $index
        }
    }

    It 'puts live fleet state ahead of curated context, so a truncated tail takes the cheapest thing' {
        New-TestHome -Populated | Out-Null
        $digest = @(Get-FmSessionStartDigest)
        (Get-SectionIndex -Digest $digest -Title 'FLEET STATE') |
            Should -BeLessThan (Get-SectionIndex -Digest $digest -Title 'CONTEXT')
    }

    It 'declares itself read-only and skips every mutating step when the lock owner is unavailable' {
        # The lock owner has LANDED, so this degradation is now STAGED rather
        # than assumed. A test that assumes it stops exercising the read-only
        # path the moment the owner appears - and an assumed absence is exactly
        # what let the missing owner ship in the first place.
        New-TestHome -Populated | Out-Null
        Mock Resolve-FmSessionCommand {
            # One mock, not a filtered pair: Pester has no fall-through to the
            # real command for an unmatched filter, and this stage resolves
            # several other owners in the same run.
            if ($Name -contains 'Invoke-FmLock') { return $null }
            foreach ($n in $Name) {
                $c = Get-Command -Name $n -CommandType Function, Cmdlet, Alias -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($c) { return $c }
            }
            return $null
        }
        $digest = @(Get-FmSessionStartDigest)
        $digest | Should -Contain '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED'
        @($digest | Where-Object { $_ -like 'skipped (read-only session) - * record(s) remain queued*' }).Count | Should -Be 1
        $digest | Should -Contain 'skipped (read-only session) - GitHub authentication, project clone refresh,'
    }

    It 'acquires the lock through the REAL owner and is not read-only' {
        # The headline regression: every session on this port came up
        # read-only because the digest resolved a name nothing defined. No
        # stub here on purpose - a stub is what hid it.
        $home_ = New-TestHome -Populated
        function Get-FmHarnessAncestryPid { $PID }
        try {
            $digest = @(Get-FmSessionStartDigest)
            $digest | Should -Contain "lock acquired: harness pid $PID"
            $digest | Should -Not -Contain '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED'
            @($digest | Where-Object { $_ -like 'lock: NOT ACQUIRED*' }).Count | Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $home_ 'state' '.lock')) | Should -Be "$PID`n"
        } finally {
            Remove-Item -Path 'function:Get-FmHarnessAncestryPid' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits a supervision operating block, never the not-emitted degradation' {
        New-TestHome -Populated | Out-Null
        $digest = @(Get-FmSessionStartDigest)
        @($digest | Where-Object { $_ -like 'SUPERVISION INSTRUCTIONS: NOT EMITTED*' }).Count | Should -Be 0
        @($digest | Where-Object { $_ -like 'SUPERVISION OPERATING INSTRUCTIONS - primary harness:*' }).Count | Should -Be 1
    }

    It 'runs the locked path, drains the queue and records completion when the lock owner is loaded' {
        $home_ = New-TestHome -Populated
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' '.lock'), "4242`n")
        function Invoke-FmLock { 'lock acquired: harness pid 4242' }
        function Invoke-FmWakeDrain { 'WAKE_ACK_REQUIRED: after handling completes run the ack command' }
        try {
            $digest = @(Get-FmSessionStartDigest)
            $digest | Should -Contain 'lock acquired: harness pid 4242'
            $digest | Should -Not -Contain '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED'
            $digest | Should -Contain 'WAKE_ACK_REQUIRED: after handling completes run the ack command'
            # The completion record is what lets a later /clear re-emit instead of
            # re-running the mutating sweeps, and it is an LF-only file contract.
            [System.IO.File]::ReadAllText((Join-Path $home_ 'state' '.session-start-complete')) | Should -Be "4242`n"
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock', 'function:Invoke-FmWakeDrain' -ErrorAction SilentlyContinue
        }
    }

    It 'says a wake drain did not happen rather than printing a reassuring nothing' {
        # The watcher area ships a real Invoke-FmWakeDrain, so the absence this
        # line reports has to be staged. Deleting the function is not enough: the
        # foundation suites import the manifest, and an imported module keeps
        # exporting the name however the test session's own function table is
        # edited. Withhold it at the seam that actually decides - the by-name
        # resolution - and delegate every OTHER name to the real resolver, so
        # this stays a test of the digest's degradation reporting rather than of
        # an empty module build.
        $realResolve = (Get-Command -Name 'Resolve-FmSessionCommand').ScriptBlock
        Mock Resolve-FmSessionCommand {
            if ($Name -contains 'Invoke-FmWakeDrain') { return $null }
            return (& $realResolve -Name $Name)
        }
        New-TestHome -Populated | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $env:FM_HOME 'state' '.lock'), "4242`n")
        function Invoke-FmLock { 'lock acquired: harness pid 4242' }
        try {
            $digest = @(Get-FmSessionStartDigest)
            $digest | Should -Contain 'wake queue: NOT DRAINED - Invoke-FmWakeDrain is not available in this module build, so queued wakes were neither presented nor acknowledged.'
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock' -ErrorAction SilentlyContinue
        }
    }

    It 'reports the re-emit banner and does not clear the completion record' {
        $home_ = New-TestHome -Populated
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' '.lock'), "4242`n")
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' '.session-start-complete'), "4242`n")
        function Invoke-FmLock { 'lock acquired: harness pid 4242' }
        try {
            $digest = @(Get-FmSessionStartDigest -Reemit)
            @($digest | Where-Object { $_ -like 'SESSION START (CONTEXT RE-EMIT) - *' }).Count | Should -Be 1
            $digest | Should -Contain 'Queued wakes ARE still drained: they arrived after startup and are this turn work.'
            Test-Path -LiteralPath (Join-Path $home_ 'state' '.session-start-complete') | Should -BeTrue
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock' -ErrorAction SilentlyContinue
        }
    }

    It 'lists every in-flight task with its endpoint verdict and status tail' {
        New-TestHome -Populated | Out-Null
        function Get-FmMetaBackend { param($Path) 'tmux' }
        function Get-FmMetaTarget { param($Path) '' }
        function Test-FmBackendTargetExists { param($Backend, $Target, $Name) $false }
        try {
            $digest = @(Get-FmSessionStartDigest)
            $digest | Should -Contain '--- task-a ---'
            $digest | Should -Contain 'endpoint: dead (backend=tmux window=fm-task-a)'
        } finally {
            Remove-Item -Path 'function:Get-FmMetaBackend', 'function:Get-FmMetaTarget', 'function:Test-FmBackendTargetExists' -ErrorAction SilentlyContinue
        }
    }

    It 'lists an orphan status log separately from work under way' {
        New-TestHome -Populated | Out-Null
        $digest = @(Get-FmSessionStartDigest)
        $orphanHeading = Get-SectionIndex -Digest $digest -Title 'Orphan status logs (state/*.status without matching .meta)'
        $orphanHeading | Should -BeGreaterThan 0
        $digest | Should -Contain '--- orphan ---'
    }

    It 'prints an explicit (none) for an empty home rather than an ambiguous blank' {
        New-TestHome | Out-Null
        $digest = @(Get-FmSessionStartDigest)
        $digest | Should -Contain 'ABSENT'
        $digest | Should -Contain '(none)'
        $digest | Should -Contain 'absent'
    }

    It 'closes with the read-once reminder' {
        New-TestHome | Out-Null
        $digest = @(Get-FmSessionStartDigest)
        $digest[-1] | Should -Be 'section near the top of it governs what may still be read from disk.'
    }
}

Describe 'Invoke-FmSessionStart' {
    It 'runs the digest in-process without -Bounded' {
        New-TestHome | Out-Null
        $digest = @(Invoke-FmSessionStart)
        (Get-SectionIndex -Digest $digest -Title 'READ-ONCE CONTRACT') | Should -BeGreaterThan 0
    }

    It 'runs unbounded, and says so, rather than not running at all when the entry script is missing' {
        New-TestHome | Out-Null
        $digest = @(Invoke-FmSessionStart -Bounded -EntryScript (Join-Path $TestDrive 'no-such-entry.ps1'))
        $digest[0] | Should -BeLike 'SESSION START: runtime bound skipped - entry script not found at *'
        (Get-SectionIndex -Digest $digest -Title 'READ-ONCE CONTRACT') | Should -BeGreaterThan 0
    }
}

Describe 'the bounded runtime and its truncation banner' {
    It 'delivers everything the child emitted and names the stage that did not finish' {
        New-TestHome | Out-Null
        # A stand-in child that emits two lines, records a stage, and then hangs:
        # the real digest's stages are exercised above, and what needs proving here
        # is that the bound fires, the partial output survives, and the banner
        # names the right stage.
        $entry = Join-Path $TestDrive 'slow-entry.ps1'
        [System.IO.File]::WriteAllText($entry, @'
$out = $env:FM_SESSION_START_OUTPUT_FILE
$writer = [System.IO.StreamWriter]::new($out, $true, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$writer.NewLine = "`n"
$writer.WriteLine('first line')
$writer.WriteLine('second line')
[System.IO.File]::WriteAllText($env:FM_SESSION_START_STAGE_FILE, "fleet-state`n")
Start-Sleep -Seconds 30
'@)
        $env:FM_SESSION_START_TIMEOUT = '3'
        $output = @(Invoke-FmSessionStartBounded -EntryScript $entry)

        $output | Should -Contain 'first line'
        $output | Should -Contain 'second line'
        $output | Should -Contain '●  STARTUP TRUNCATED - SESSION START HIT ITS 3s RUNTIME BOUND'
        $output | Should -Contain '●  It stopped during the "fleet-state" stage, so everything above is COMPLETE'
        # Every stage from the interrupted one onward is named as never emitted.
        $output | Should -Contain '●    fleet-state network-checks context next-step'
    }

    It 'prints no truncation banner when the child finishes inside the bound' {
        New-TestHome | Out-Null
        $entry = Join-Path $TestDrive 'fast-entry.ps1'
        [System.IO.File]::WriteAllText($entry, @'
$writer = [System.IO.StreamWriter]::new($env:FM_SESSION_START_OUTPUT_FILE, $true, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$writer.NewLine = "`n"
$writer.WriteLine('complete digest')
$writer.Dispose()
'@)
        $env:FM_SESSION_START_TIMEOUT = '60'
        $output = @(Invoke-FmSessionStartBounded -EntryScript $entry)
        $output | Should -Contain 'complete digest'
        @($output | Where-Object { $_ -like '*STARTUP TRUNCATED*' }).Count | Should -Be 0
    }
}

Describe 'Invoke-FmSessionLockStage' {
    # The lock stage is the one stage whose result decides what the rest of the
    # digest may do, so every shape of refusal has to land on read-only.
    It 'is read-only when the lock owner is not loaded at all' {
        New-TestHome | Out-Null
        Mock Resolve-FmSessionCommand {
            # One mock, not a filtered pair: Pester has no fall-through to the
            # real command for an unmatched filter, and this stage resolves
            # several other owners in the same run.
            if ($Name -contains 'Invoke-FmLock') { return $null }
            foreach ($n in $Name) {
                $c = Get-Command -Name $n -CommandType Function, Cmdlet, Alias -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($c) { return $c }
            }
            return $null
        }
        $lock = Invoke-FmSessionLockStage
        $lock.Acquired | Should -BeFalse
        $lock.Output[0] | Should -BeLike 'lock: NOT ACQUIRED - *'
    }

    It 'reads the REAL owner refusal as read-only, with its reason verbatim' {
        # Invoke-FmLock reports refusal on the error stream and returns no
        # object, so this stage's "an error record means not acquired" branch
        # is the one that actually runs in production.
        New-TestHome | Out-Null
        function Get-FmHarnessAncestryPid { $null }
        try {
            $lock = Invoke-FmSessionLockStage
            $lock.Acquired | Should -BeFalse
            ($lock.Output -join ' ') | Should -BeLike '*cannot locate harness process in ancestry*'
        } finally {
            Remove-Item -Path 'function:Get-FmHarnessAncestryPid' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is read-only when the lock owner throws' {
        New-TestHome | Out-Null
        function Invoke-FmLock { throw 'another live session holds the lock (pid 1234)' }
        try {
            $lock = Invoke-FmSessionLockStage
            $lock.Acquired | Should -BeFalse
            $lock.Output[0] | Should -BeLike '*another live session holds the lock*'
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock' -ErrorAction SilentlyContinue
        }
    }

    It 'is read-only when the lock owner returns a refusal record' {
        New-TestHome | Out-Null
        function Invoke-FmLock { [pscustomobject]@{ Acquired = $false; Message = 'refused: pid 1234 is live' } }
        try {
            (Invoke-FmSessionLockStage).Acquired | Should -BeFalse
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock' -ErrorAction SilentlyContinue
        }
    }

    It 'acquires when the owner returns plain confirmation lines' {
        New-TestHome | Out-Null
        function Invoke-FmLock { 'lock acquired: harness pid 4242' }
        try {
            $lock = Invoke-FmSessionLockStage
            $lock.Acquired | Should -BeTrue
            $lock.Output[0] | Should -Be 'lock acquired: harness pid 4242'
        } finally {
            Remove-Item -Path 'function:Invoke-FmLock' -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-FmSessionEndpointLine' {
    # The endpoint read is a fast PRESENCE check the backend area owns. What
    # matters here is that the digest binds to the probe that area actually
    # publishes, and reports "unknown" rather than guessing when none fits.
    It 'uses the herdr presence probe for a herdr endpoint' {
        New-TestHome -Populated | Out-Null
        $meta = Join-Path $env:FM_HOME 'state' 'task-a.meta'
        [System.IO.File]::WriteAllText($meta, "window=fm-task-a`nbackend=herdr`n")
        function Test-FmHerdrTargetExists { param($Target) $true }
        try {
            Get-FmSessionEndpointLine -MetaPath $meta -TaskId 'task-a' -Window 'fm-task-a' |
                Should -Be 'endpoint: alive (backend=herdr window=fm-task-a)'
        } finally {
            Remove-Item -Path 'function:Test-FmHerdrTargetExists' -ErrorAction SilentlyContinue
        }
    }

    It 'reports unknown, naming the backend, when no probe for it is loaded' {
        New-TestHome -Populated | Out-Null
        $meta = Join-Path $env:FM_HOME 'state' 'task-a.meta'
        [System.IO.File]::WriteAllText($meta, "window=fm-task-a`nbackend=zellij`n")
        Get-FmSessionEndpointLine -MetaPath $meta -TaskId 'task-a' -Window 'fm-task-a' |
            Should -Be "endpoint: unknown (no endpoint probe is loaded for backend 'zellij'; window=fm-task-a)"
    }
}
