#requires -Version 7.0
# Pester tests for the manual backlog backend.
#
# Two kinds of expectation live here. Most are structural: the grammar, the
# canonical rendering, the idempotent verbs, retention, and every refusal path.
# The last Describe is DIFFERENTIAL: when a compatible tasks-axi happens to be on
# PATH, the same mutation sequence is run through both implementations and the
# resulting files are compared byte for byte, because tasks-axi's markdown
# backend is the format owner and this port has to stay readable by it.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes and repos. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    $script:Fixture = @(
        '# Backlog',
        '',
        '## In flight',
        '- [ ] task-a - doing things (repo: alpha) (since 2026-08-01)',
        '  body line one',
        '',
        '  body paragraph two',
        '',
        '## Queued',
        '- [ ] task-b - later (repo: alpha) (since 2026-08-02) (hold: waiting on captain) (hold-kind: captain)',
        '- [ ] task-c - other (repo: beta) (since 2026-08-03) blocked-by: task-a - waits on the refactor',
        '## Done',
        '- [x] task-z - finished https://github.com/o/r/pull/42 (merged 2026-08-01)'
    )

    function New-BacklogFile {
        param([string[]]$Line = $script:Fixture, [string]$Name = 'backlog.md')
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir $Name
        [System.IO.File]::WriteAllText($path, (($Line -join "`n") + "`n"))
        $path
    }

    function Get-Text { param([string]$Path) [System.IO.File]::ReadAllText($Path) }
    function Get-Ids {
        param($Task)
        (@($Task) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Id }) -join ','
    }
}

Describe 'the grammar round-trips byte for byte' {
    It 're-emits an untouched file exactly as it was read' {
        $path = New-BacklogFile
        $text = Get-Text -Path $path
        ConvertTo-FmBacklogMarkdown -Document (ConvertFrom-FmBacklogMarkdown -Text $text) | Should -Be $text
    }

    It 'preserves a file with no trailing newline' {
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'backlog.md'
        $text = "# Backlog`n`n## Queued`n- [ ] a - one"
        [System.IO.File]::WriteAllText($path, $text)
        ConvertTo-FmBacklogMarkdown -Document (ConvertFrom-FmBacklogMarkdown -Text $text) | Should -Be $text
    }

    It 'leaves every other item byte-identical when one item is mutated' {
        $path = New-BacklogFile
        $before = (Get-Text -Path $path) -split "`n"
        $null = Set-FmBacklogHold -Id 'task-c' -Reason 'waiting for upstream' -Kind external -Path $path
        $after = (Get-Text -Path $path) -split "`n"
        foreach ($index in 0, 1, 2, 3, 4, 5, 6, 7, 8, 9) {
            $after[$index] | Should -Be $before[$index] -Because "line $index belongs to another item"
        }
        $after[11] | Should -Be $before[11]
    }

    It 'parses the legacy - **id** in-flight bullet and normalises it only when rewritten' {
        $path = New-BacklogFile -Line @('## In flight', '- **task-a** - legacy bullet', '## Queued', '## Done')
        (Get-FmBacklogTask -Id 'task-a' -Path $path).Title | Should -Be 'legacy bullet'
        (Get-Text -Path $path) | Should -Match '- \*\*task-a\*\*'
        $null = Set-FmBacklogHold -Id 'task-a' -Reason 'captain decision pending' -Kind captain -Path $path
        (Get-Text -Path $path) | Should -Match '- \[ \] task-a - legacy bullet \(hold: captain decision pending\)'
    }

    It 'keeps a mid-sentence parenthetical in the prose and never relocates it' {
        $path = New-BacklogFile -Line @('## Queued', '- [ ] a - see report.md (reported 2026-06-22): the note (repo: x) (since 2026-08-01)', '## Done')
        $task = Get-FmBacklogTask -Id 'a' -Path $path
        $task.Title | Should -Be 'see report.md (reported 2026-06-22): the note'
        $task.Repo | Should -Be 'x'
        (Get-FmBacklogTaskLine -Task $task) -join '' | Should -Match 'report\.md \(reported 2026-06-22\): the note \(repo: x\) \(since 2026-08-01\)'
    }
}

Describe 'reading the backlog' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'reads every field off a bullet' {
        $task = Get-FmBacklogTask -Id 'task-b' -Path $script:path
        $task.State | Should -Be 'queued'
        $task.Title | Should -Be 'later'
        $task.Repo | Should -Be 'alpha'
        $task.Created | Should -Be '2026-08-02'
        $task.Hold.Reason | Should -Be 'waiting on captain'
        $task.Hold.Kind | Should -Be 'captain'
    }

    It 'reads a dependency edge with its free-text reason' {
        $dep = @((Get-FmBacklogTask -Id 'task-c' -Path $script:path).Deps)[0]
        $dep.Type | Should -Be 'blocked-by'
        $dep.Id | Should -Be 'task-a'
        $dep.Reason | Should -Be 'waits on the refactor'
    }

    It 'keeps a multi-paragraph body, blank line and all' {
        (Get-FmBacklogTask -Id 'task-a' -Path $script:path).Body | Should -Be "body line one`n`nbody paragraph two"
    }

    It 'derives typed links from the prose' {
        $links = @((Get-FmBacklogTask -Id 'task-z' -Path $script:path).Links)
        $links.Count | Should -Be 1
        $links[0].Kind | Should -Be 'pr'
        $links[0].Url | Should -Be 'https://github.com/o/r/pull/42'
    }

    It 'filters by state, repo and kind' {
        (Get-Ids (Get-FmBacklog -Path $script:path -State queued)) | Should -Be 'task-b,task-c'
        (Get-Ids (Get-FmBacklog -Path $script:path -Repo beta)) | Should -Be 'task-c'
        (Get-Ids (Get-FmBacklog -Path $script:path -Kind captain)) | Should -Be ''
    }

    It 'returns nothing for a backlog file that does not exist' {
        @(Get-FmBacklog -Path (Join-Path $TestDrive 'nope.md')).Count | Should -Be 0
    }

    It 'reads an EMPTY backlog, which is nothing but headers and blank lines' {
        # The shape every fresh home has, and the one the main fixture never
        # produces: its blank lines all sit inside an item body, so they are
        # consumed by the body scan and never offered to the bullet matcher. A
        # blank line in an item-less section IS offered to it, and the matcher
        # used to refuse to bind one at all - so Get-FmBacklog raised instead of
        # answering "no tasks" for a home that simply had no work yet.
        $path = New-BacklogFile -Line @('# Backlog', '', '## In flight', '', '## Queued', '', '## Done', '')
        @(Get-FmBacklog -Path $path).Count | Should -Be 0
        @(Get-FmBacklog -Path $path -State 'in_flight').Count | Should -Be 0
    }
}

Describe 'the TASKS_AXI_FILE override' {
    # Saved and restored rather than just cleared: the whole suite shares one
    # process, so a stray $env:TASKS_AXI_FILE left set here would decide another
    # file's backlog resolution.
    BeforeAll { $script:priorAxiFile = $env:TASKS_AXI_FILE }
    AfterAll {
        if ($null -eq $script:priorAxiFile) {
            Remove-Item -LiteralPath 'env:TASKS_AXI_FILE' -ErrorAction SilentlyContinue
        } else {
            $env:TASKS_AXI_FILE = $script:priorAxiFile
        }
    }
    AfterEach { Remove-Item -LiteralPath 'env:TASKS_AXI_FILE' -ErrorAction SilentlyContinue }

    It 'lets TASKS_AXI_FILE override which file a home resolves to' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $env:TASKS_AXI_FILE = Join-Path $TestDrive 'elsewhere.md'
        (Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'no-home-config.toml')).Path |
            Should -Be $env:TASKS_AXI_FILE
    }

    It 'IGNORES that override when the caller is asking about another home' {
        # TASKS_AXI_FILE is process-wide, so a question about a DIFFERENT home -
        # a secondmate retirement asking whether that home has work in flight -
        # would otherwise be answered from this home's file. The verdict decides
        # whether a home is deleted, so it reads that home's own record.
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        $env:TASKS_AXI_FILE = Join-Path $TestDrive 'elsewhere.md'
        (Get-FmBacklogConfig -Root $root -IgnoreEnvironment `
                -HomeConfigPath (Join-Path $TestDrive 'no-home-config.toml')).Path |
            Should -Be (Join-Path $root 'data' 'backlog.md')
    }
}

Describe 'derived ready, held and blocked projections' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'excludes blocked and held work from ready' {
        (Get-Ids (Get-FmBacklogReady -Path $script:path)) | Should -Be ''
        (Get-Ids (Get-FmBacklogHeld -Path $script:path)) | Should -Be 'task-b'
        (Get-Ids (Get-FmBacklogBlocked -Path $script:path)) | Should -Be 'task-c'
    }

    It 'releases a blocked item when its blocker lands' {
        $null = Complete-FmBacklogTask -Id 'task-a' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-Ids (Get-FmBacklogReady -Path $script:path)) | Should -Be 'task-c'
    }

    It 'shows held work in ready only when asked' {
        # task-c stays out: -IncludeHeld relaxes the hold gate, never the blocker gate.
        (Get-Ids (Get-FmBacklogReady -Path $script:path -IncludeHeld)) | Should -Be 'task-b'
    }

    It 'treats a dangling blocker as resolved, the way a hand-edited file means it' {
        $path = New-BacklogFile -Line @('## Queued', '- [ ] a - one blocked-by: ghost', '## Done')
        (Get-Ids (Get-FmBacklogReady -Path $path)) | Should -Be 'a'
    }

    It 'stops a hold-until on the named date, not after it' {
        $path = New-BacklogFile -Line @('## Queued', '- [ ] a - one (hold: later) (hold-until: 2026-07-10)', '## Done')
        (Get-Ids (Get-FmBacklogReady -Path $path -Today '2026-07-09')) | Should -Be ''
        (Get-Ids (Get-FmBacklogReady -Path $path -Today '2026-07-10')) | Should -Be 'a'
    }

    It 'never treats a done item as held' {
        $path = New-BacklogFile -Line @('## Queued', '## Done', '- [x] a - one (hold: stale) (done 2026-08-01)')
        (Get-Ids (Get-FmBacklogHeld -Path $path)) | Should -Be ''
    }
}

Describe 'add' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'appends queued work to the bottom of Queued' {
        $null = Add-FmBacklogTask -Id 'task-d' -Title 'new thing' -Repo 'alpha' -Path $script:path -Date '2026-08-12'
        (Get-Ids (Get-FmBacklog -Path $script:path -State queued)) | Should -Be 'task-b,task-c,task-d'
        (Get-Text -Path $script:path) | Should -Match '- \[ \] task-d - new thing \(repo: alpha\) \(since 2026-08-12\)'
    }

    It 'puts new in-flight work at the top of In flight' {
        $null = Add-FmBacklogTask -Id 'task-d' -Title 'urgent' -Start -Path $script:path -Date '2026-08-12'
        (Get-Ids (Get-FmBacklog -Path $script:path -State in_flight)) | Should -Be 'task-d,task-a'
    }

    It 'creates the sections when the file does not exist yet' {
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.md')
        $null = Add-FmBacklogTask -Id 'first' -Title 'the first item' -Path $path -Date '2026-08-12'
        $text = Get-Text -Path $path
        $text | Should -Match '(?m)^# Backlog$'
        $text | Should -Match '(?m)^## In flight$'
        $text | Should -Match '(?m)^## Queued$'
        $text | Should -Match '(?m)^## Done$'
    }

    It 'records a blocker edge and refuses one that does not exist' {
        $null = Add-FmBacklogTask -Id 'task-d' -Title 'dependent' -BlockedBy @('task-a') -Path $script:path -Date '2026-08-12'
        @((Get-FmBacklogTask -Id 'task-d' -Path $script:path).Deps)[0].Id | Should -Be 'task-a'
        { Add-FmBacklogTask -Id 'task-e' -Title 'x' -BlockedBy @('ghost') -Path $script:path } |
            Should -Throw '*blocker "ghost" not found*'
    }

    It 'refuses a duplicate id' {
        { Add-FmBacklogTask -Id 'task-a' -Title 'again' -Path $script:path } | Should -Throw '*already exists*'
    }

    It 'refuses an id the grammar cannot round-trip' {
        { Add-FmBacklogTask -Id 'bad id' -Title 'x' -Path $script:path } | Should -Throw '*invalid task id*'
        { Add-FmBacklogTask -Id '-leading' -Title 'x' -Path $script:path } | Should -Throw '*invalid task id*'
    }

    It 'refuses an empty title, a multi-line title, and a title ending in canonical tags' {
        { Add-FmBacklogTask -Id 'x1' -Title '   ' -Path $script:path } | Should -Throw '*must not be empty*'
        { Add-FmBacklogTask -Id 'x2' -Title "two`nlines" -Path $script:path } | Should -Throw '*single line*'
        { Add-FmBacklogTask -Id 'x3' -Title 'thing (repo: alpha)' -Path $script:path } |
            Should -Throw '*must not end with canonical task tags*'
    }

    It 'refuses a priority outside 0-4' {
        { Add-FmBacklogTask -Id 'x4' -Title 'x' -Priority 9 -Path $script:path } | Should -Throw '*0-4*'
    }

    It 'refuses to create a public-followup obligation' {
        { Add-FmBacklogTask -Id 'x5' -Title 'x' -Kind 'public-followup' -Path $script:path } |
            Should -Throw '*public-followup command family*'
    }

    It 'writes LF only, with no BOM' {
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.md')
        $null = Add-FmBacklogTask -Id 'first' -Title 'the first item' -Path $path -Date '2026-08-12'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Not -Be 0xEF
        ($bytes -contains 0x0D) | Should -BeFalse
    }
}

Describe 'start and reopen' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'moves a queued item to In flight' {
        $result = Start-FmBacklogTask -Id 'task-b' -Path $script:path
        $result.Already | Should -BeFalse
        (Get-FmBacklogTask -Id 'task-b' -Path $script:path).State | Should -Be 'in_flight'
    }

    It 'is idempotent and does not touch the file when already in flight' {
        $before = Get-Text -Path $script:path
        $result = Start-FmBacklogTask -Id 'task-a' -Path $script:path
        $result.Already | Should -BeTrue
        Get-Text -Path $script:path | Should -Be $before
    }

    It 'stamps a since date on an item that had none' {
        $path = New-BacklogFile -Line @('## In flight', '## Queued', '- [ ] a - undated', '## Done')
        $null = Start-FmBacklogTask -Id 'a' -Path $path -Date '2026-08-12'
        (Get-FmBacklogTask -Id 'a' -Path $path).Created | Should -Be '2026-08-12'
    }

    It 'reopens done work back to the bottom of Queued and clears its close date' {
        $null = Reset-FmBacklogTask -Id 'task-z' -Path $script:path
        $task = Get-FmBacklogTask -Id 'task-z' -Path $script:path
        $task.State | Should -Be 'queued'
        $task.Closed | Should -Be ''
        (Get-Ids (Get-FmBacklog -Path $script:path -State queued)) | Should -Be 'task-b,task-c,task-z'
    }

    It 'refuses an unknown id' {
        { Start-FmBacklogTask -Id 'ghost' -Path $script:path } | Should -Throw '*not found*'
        { Reset-FmBacklogTask -Id 'ghost' -Path $script:path } | Should -Throw '*not found*'
    }
}

Describe 'done, and the configured recent-Done retention' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'closes an item at the top of Done with its close date' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-Ids (Get-FmBacklog -Path $script:path -State done)) | Should -Be 'task-b,task-z'
        (Get-FmBacklogTask -Id 'task-b' -Path $script:path).Closed | Should -Be '2026-08-12'
    }

    It 'uses merged, reported or done as the closure verb, following the evidence' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-Text -Path $script:path) | Should -Match '\(done 2026-08-12\)'
        $null = Complete-FmBacklogTask -Id 'task-c' -Pr 'https://github.com/o/r/pull/7' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-Text -Path $script:path) | Should -Match '\(merged 2026-08-12\)'
        $null = Add-FmBacklogTask -Id 'scout-1' -Title 'scouted' -Path $script:path -Date '2026-08-12'
        $null = Complete-FmBacklogTask -Id 'scout-1' -Report 'data/scout-1/report.md' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-Text -Path $script:path) | Should -Match '\(reported 2026-08-12\)'
    }

    It 'appends a note to the body' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Note 'merged via chain; local main' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-FmBacklogTask -Id 'task-b' -Path $script:path).Body | Should -Be 'merged via chain; local main'
    }

    It 'backfills links on a re-run without changing the close date' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Path $script:path -NoPrune -Date '2026-08-12'
        $result = Complete-FmBacklogTask -Id 'task-b' -Pr 'https://github.com/o/r/pull/8' -Path $script:path -NoPrune -Date '2026-08-20'
        $result.Already | Should -BeTrue
        $result.Task.Closed | Should -Be '2026-08-12'
        $result.Task.Title | Should -Match 'pull/8'
    }

    It 'never adds the same note or link twice' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Note 'shipped' -Path $script:path -NoPrune -Date '2026-08-12'
        $null = Complete-FmBacklogTask -Id 'task-b' -Note 'shipped' -Path $script:path -NoPrune -Date '2026-08-12'
        (Get-FmBacklogTask -Id 'task-b' -Path $script:path).Body | Should -Be 'shipped'
    }

    It 'keeps only the configured most recent Done rows and archives the surplus' {
        $null = Complete-FmBacklogTask -Id 'task-b' -Path $script:path -Keep 1 -Date '2026-08-12'
        (Get-Ids (Get-FmBacklog -Path $script:path -State done)) | Should -Be 'task-b'
        $archive = Join-Path (Split-Path -Parent $script:path) 'done-archive.md'
        $text = Get-Text -Path $archive
        $text | Should -Match '## Archived 2026-08-12'
        $text | Should -Match '- \[x\] task-z - finished'
    }

    It 'archives a surplus row with its ORIGINAL lines, never a reflowed one' {
        $path = New-BacklogFile -Line @('## Queued', '- [ ] a - one', '## Done',
            '- [x] keep - kept (done 2026-08-02)',
            '- [x] old - odd    spacing   preserved (done 2026-08-01)')
        $null = Invoke-FmBacklogPrune -Path $path -Keep 1 -Date '2026-08-12'
        (Get-Text -Path (Join-Path (Split-Path -Parent $path) 'done-archive.md')) |
            Should -Match 'odd    spacing   preserved'
    }

    It 'reports how many rows retention archived' {
        $result = Complete-FmBacklogTask -Id 'task-b' -Path $script:path -Keep 0 -Date '2026-08-12'
        $result.Pruned | Should -Be 2
    }

    It 'archives nothing when the Done section is already within the limit' {
        $result = Invoke-FmBacklogPrune -Path $script:path -Keep 10 -Date '2026-08-12'
        $result.Archived | Should -Be 0
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $script:path) 'done-archive.md') | Should -BeFalse
    }

    It 'refuses an unknown id' {
        { Complete-FmBacklogTask -Id 'ghost' -Path $script:path } | Should -Throw '*not found*'
    }

    It 'refuses a pr link that is not a pull request URL' {
        { Complete-FmBacklogTask -Id 'task-b' -Pr 'https://github.com/o/r/issues/7' -Path $script:path } |
            Should -Throw '*pull request URL*'
    }

    It 'refuses a report link that is not a report path' {
        { Complete-FmBacklogTask -Id 'task-b' -Report 'notes.md' -Path $script:path } |
            Should -Throw '*report.md*'
    }
}

Describe 'block and unblock' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'records an edge and is idempotent' {
        $first = Block-FmBacklogTask -Id 'task-b' -By 'task-a' -Path $script:path
        $first.Already | Should -BeFalse
        (Get-Ids (Get-FmBacklogBlocked -Path $script:path)) | Should -Be 'task-b,task-c'
        $second = Block-FmBacklogTask -Id 'task-b' -By 'task-a' -Path $script:path
        $second.Already | Should -BeTrue
    }

    It 'refuses a blocker that does not exist' {
        { Block-FmBacklogTask -Id 'task-b' -By 'ghost' -Path $script:path } | Should -Throw '*blocker "ghost" not found*'
    }

    It 'refuses a self-block' {
        { Block-FmBacklogTask -Id 'task-b' -By 'task-b' -Path $script:path } | Should -Throw '*cannot block itself*'
    }

    It 'refuses a reason carrying a dependency marker' {
        { Block-FmBacklogTask -Id 'task-b' -By 'task-a' -Reason 'blocked-by: other' -Path $script:path } |
            Should -Throw '*dependency markers*'
    }

    It 'clears an edge and is idempotent' {
        $first = Unblock-FmBacklogTask -Id 'task-c' -By 'task-a' -Path $script:path
        $first.Already | Should -BeFalse
        (Get-Ids (Get-FmBacklogBlocked -Path $script:path)) | Should -Be ''
        (Unblock-FmBacklogTask -Id 'task-c' -By 'task-a' -Path $script:path).Already | Should -BeTrue
    }

    It 'keeps a reason on the edge and re-renders it after the parenthetical tags' {
        $null = Block-FmBacklogTask -Id 'task-b' -By 'task-a' -Reason 'waits on the lease' -Path $script:path
        (Get-Text -Path $script:path) |
            Should -Match '- \[ \] task-b - later \(repo: alpha\) \(since 2026-08-02\) \(hold: waiting on captain\) \(hold-kind: captain\) blocked-by: task-a - waits on the lease'
    }

    It 'refuses an unknown task' {
        { Block-FmBacklogTask -Id 'ghost' -By 'task-a' -Path $script:path } | Should -Throw '*not found*'
        { Unblock-FmBacklogTask -Id 'ghost' -By 'task-a' -Path $script:path } | Should -Throw '*not found*'
    }
}

Describe 'hold and unhold' {
    BeforeEach { $script:path = New-BacklogFile }

    It 'records a hold with kind and until, and is idempotent' {
        $first = Set-FmBacklogHold -Id 'task-c' -Reason 'start after launch' -Kind future -Until '2026-09-01' -Path $script:path
        $first.Already | Should -BeFalse
        (Get-Text -Path $script:path) | Should -Match '\(hold: start after launch\) \(hold-kind: future\) \(hold-until: 2026-09-01\)'
        (Set-FmBacklogHold -Id 'task-c' -Reason 'start after launch' -Kind future -Until '2026-09-01' -Path $script:path).Already |
            Should -BeTrue
    }

    It 'clears a hold and is idempotent' {
        (Clear-FmBacklogHold -Id 'task-b' -Path $script:path).Already | Should -BeFalse
        (Get-FmBacklogTask -Id 'task-b' -Path $script:path).Hold | Should -BeNullOrEmpty
        (Clear-FmBacklogHold -Id 'task-b' -Path $script:path).Already | Should -BeTrue
    }

    It 'refuses an empty reason and one carrying parentheses' {
        { Set-FmBacklogHold -Id 'task-c' -Reason '  ' -Path $script:path } | Should -Throw '*must not be empty*'
        { Set-FmBacklogHold -Id 'task-c' -Reason 'because (reasons)' -Path $script:path } |
            Should -Throw '*without parentheses*'
    }

    It 'refuses an unknown hold kind and a malformed until date' {
        { Set-FmBacklogHold -Id 'task-c' -Reason 'x' -Kind 'whenever' -Path $script:path } | Should -Throw '*hold kind must be one of*'
        { Set-FmBacklogHold -Id 'task-c' -Reason 'x' -Until '09-2026' -Path $script:path } | Should -Throw '*YYYY-MM-DD*'
    }

    It 'refuses an unknown task' {
        { Set-FmBacklogHold -Id 'ghost' -Reason 'x' -Path $script:path } | Should -Throw '*not found*'
        { Clear-FmBacklogHold -Id 'ghost' -Path $script:path } | Should -Throw '*not found*'
    }
}

Describe 'public-followup obligations are refused, not corrupted' {
    BeforeEach {
        # An intent-state obligation: kind=public-followup with its typed metadata
        # line, encoded exactly as tasks-axi encodes it.
        $payload = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes('{"revision":1,"delivery":{"state":"intent"}}')).
        Replace('+', '-').Replace('/', '_').TrimEnd('=')
        $script:path = New-BacklogFile -Line @(
            '## In flight',
            '## Queued',
            "- [ ] promise-1 - a public promise (kind: public-followup) (since 2026-08-01)",
            "  <!-- tasks-axi:public-followup/v1:$payload -->",
            '## Done')
    }

    It 'reads and round-trips one without touching it' {
        $text = Get-Text -Path $script:path
        (Get-FmBacklogTask -Id 'promise-1' -Path $script:path).Kind | Should -Be 'public-followup'
        ConvertTo-FmBacklogMarkdown -Document (ConvertFrom-FmBacklogMarkdown -Text $text) | Should -Be $text
    }

    It 'never lists one as dispatchable work' {
        (Get-Ids (Get-FmBacklogReady -Path $script:path)) | Should -Be ''
    }

    It 'refuses every generic mutation on one' {
        { Start-FmBacklogTask -Id 'promise-1' -Path $script:path } | Should -Throw '*public-followup command family*'
        { Complete-FmBacklogTask -Id 'promise-1' -Path $script:path } | Should -Throw '*public-followup command family*'
        { Set-FmBacklogHold -Id 'promise-1' -Reason 'x' -Path $script:path } | Should -Throw '*public-followup command family*'
        { Block-FmBacklogTask -Id 'promise-1' -By 'promise-1' -Path $script:path } | Should -Throw '*'
    }

    It 'never archives an active obligation out of the backlog' {
        $payload = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes('{"revision":1,"delivery":{"state":"intent"}}')).
        Replace('+', '-').Replace('/', '_').TrimEnd('=')
        $path = New-BacklogFile -Line @('## Queued', '## Done',
            '- [x] keep - kept (done 2026-08-02)',
            "- [x] promise-2 - a promise (kind: public-followup) (done 2026-08-01)",
            "  <!-- tasks-axi:public-followup/v1:$payload -->")
        $result = Invoke-FmBacklogPrune -Path $path -Keep 0 -Date '2026-08-12'
        $result.Ids | Should -Be @('keep')
        (Get-Text -Path $path) | Should -Match 'promise-2'
    }

    It 'refuses a metadata line that is not the first body line' {
        $path = New-BacklogFile -Line @('## Queued',
            '- [ ] promise-3 - x (kind: public-followup)',
            '  a note first',
            '  <!-- tasks-axi:public-followup/v1:AAAA -->',
            '## Done')
        { Get-FmBacklog -Path $path } | Should -Throw '*misplaced public-followup metadata*'
    }

    It 'refuses kind=public-followup with no metadata at all' {
        $path = New-BacklogFile -Line @('## Queued', '- [ ] promise-4 - x (kind: public-followup)', '## Done')
        { Get-FmBacklog -Path $path } | Should -Throw '*missing public-followup metadata*'
    }
}

Describe 'concurrent writers' {
    It 'refuses a write when the file changed under it' {
        $path = New-BacklogFile
        $source = Get-Text -Path $path
        $document = ConvertFrom-FmBacklogMarkdown -Text $source
        [System.IO.File]::AppendAllText($path, "- [x] surprise - written by someone else (done 2026-08-12)`n")
        { Save-FmBacklogDocument -Path $path -Document $document -ExpectedSource $source } |
            Should -Throw '*changed on disk*'
    }

    It 'refuses to enter a lock another writer holds' {
        $path = New-BacklogFile
        [System.IO.File]::WriteAllText("$path.lock", "someone-else`n")
        try {
            { Enter-FmBacklogLock -Path $path } | Should -Throw '*locked by another process*'
        } finally { Remove-Item -LiteralPath "$path.lock" -Force }
    }

    It 'releases only a lock it still owns' {
        $path = New-BacklogFile
        $lock = Enter-FmBacklogLock -Path $path
        [System.IO.File]::WriteAllText($lock.Path, "someone-else`n")
        Exit-FmBacklogLock -Lock $lock
        Test-Path -LiteralPath $lock.Path | Should -BeTrue -Because 'another owner''s lock must never be removed'
        Remove-Item -LiteralPath $lock.Path -Force
    }

    It 'leaves the lock file behind for no one after a normal mutation' {
        $path = New-BacklogFile
        $null = Start-FmBacklogTask -Id 'task-b' -Path $path
        Test-Path -LiteralPath "$path.lock" | Should -BeFalse
    }
}

Describe 'archive rollback' {
    It 'restores the archive to its pre-prune size' {
        $archive = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($archive, "# Archive`n")
        $point = Get-FmBacklogArchiveRestorePoint -Path $archive
        [System.IO.File]::AppendAllText($archive, "- [x] pruned - row that must be undone (done 2026-08-12)`n")

        Restore-FmBacklogArchive -Point $point
        (Get-Item -LiteralPath $archive).Length | Should -Be $point.Length
        [System.IO.File]::ReadAllText($archive) | Should -Not -BeLike '*must be undone*'
    }

    It 'removes an archive that did not exist before the prune' {
        $archive = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $point = Get-FmBacklogArchiveRestorePoint -Path $archive
        [System.IO.File]::WriteAllText($archive, "- [x] pruned - created by the prune`n")

        Restore-FmBacklogArchive -Point $point
        Test-Path -LiteralPath $archive | Should -BeFalse
    }

    It 'WARNS when it cannot roll back, instead of leaving the rows in two places silently' {
        # THE DEFECT THIS PINS. The caller appends to the archive BEFORE
        # rewriting the backlog and rolls the append back when that rewrite
        # fails, "so a failed prune never leaves a record in two places or in
        # none". A swallowed rollback failure broke exactly that invariant while
        # the caller rethrew the original save error, so the operator was told
        # the save failed and never told the archive had drifted.
        $archive = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($archive, "# Archive`n")
        $point = Get-FmBacklogArchiveRestorePoint -Path $archive
        # The restore point says the file was there; it is gone by rollback time.
        Remove-Item -LiteralPath $archive -Force

        $warnings = @()
        Restore-FmBacklogArchive -Point $point -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -BeGreaterThan 0 -Because 'a rollback that did not happen must be reported, not swallowed'
        [string]$warnings[0] | Should -BeLike '*BOTH*'
    }

    It 'does not throw out of a rollback, because the caller is already rethrowing the real error' {
        $archive = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($archive, "# Archive`n")
        $point = Get-FmBacklogArchiveRestorePoint -Path $archive
        Remove-Item -LiteralPath $archive -Force

        { Restore-FmBacklogArchive -Point $point -WarningAction SilentlyContinue } |
            Should -Not -Throw -Because 'losing the original save error to a secondary rollback failure would be the worse trade'
    }
}

Describe 'backend selection' {
    BeforeEach {
        $script:configDir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $script:configDir -Force | Out-Null
        $env:FM_TASKS_AXI_COMPATIBLE = $null
    }
    AfterEach { $env:FM_TASKS_AXI_COMPATIBLE = $null }

    It 'defaults to the tasks-axi backend when config/backlog-backend is absent' {
        Get-FmBacklogBackend -ConfigDir $script:configDir | Should -Be 'tasks-axi'
        Test-FmBacklogBackendManual -ConfigDir $script:configDir | Should -BeFalse
    }

    It 'selects the manual backend when the file says manual' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'backlog-backend'), "manual`n")
        Test-FmBacklogBackendManual -ConfigDir $script:configDir | Should -BeTrue
    }

    It 'treats an empty file as the default backend' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'backlog-backend'), "  `n")
        Get-FmBacklogBackend -ConfigDir $script:configDir | Should -Be 'tasks-axi'
    }

    It 'reports an unrecognised value verbatim rather than guessing' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'backlog-backend'), "beads`n")
        Get-FmBacklogBackend -ConfigDir $script:configDir | Should -Be 'beads'
        Test-FmBacklogBackendManual -ConfigDir $script:configDir | Should -BeFalse
    }

    It 'never routes to tasks-axi when the manual backend is selected' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'backlog-backend'), "manual`n")
        $env:FM_TASKS_AXI_COMPATIBLE = '1'
        Test-FmTasksAxiBackendAvailable -ConfigDir $script:configDir | Should -BeFalse
    }

    It 'honours a compatibility verdict handed in by a parent process' {
        $env:FM_TASKS_AXI_COMPATIBLE = '0'
        Test-FmTasksAxiCompatible | Should -BeFalse
        $env:FM_TASKS_AXI_COMPATIBLE = '1'
        Test-FmTasksAxiCompatible | Should -BeTrue -Because 'the parent already paid for the probe'
        $env:FM_TASKS_AXI_COMPATIBLE = 'maybe'
        # Anything but exactly 0 or 1 is ignored, and the probe decides.
        Test-FmTasksAxiCompatible -Force | Should -Be (Test-FmTasksAxiCompatibleProbe)
    }

    It 'compares versions against the floor' {
        Test-FmBacklogVersionAtLeast -Version '0.2.5' -Minimum '0.2.4' | Should -BeTrue
        Test-FmBacklogVersionAtLeast -Version '0.2.3' -Minimum '0.2.4' | Should -BeFalse
        Test-FmBacklogVersionAtLeast -Version '1.0.0' -Minimum '0.2.4' | Should -BeTrue
        Test-FmBacklogVersionAtLeast -Version '0.2' -Minimum '0.2.4' | Should -BeFalse
    }
}

Describe '.tasks.toml' {
    It 'reads the backend, path, archive and done_keep firstmate pins' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root '.tasks.toml'),
            "backend = `"markdown`"`n`n[markdown]`npath = `"data/backlog.md`"`narchive = `"data/done-archive.md`"`ndone_keep = 10`n")
        $config = Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.Backend | Should -Be 'markdown'
        $config.Path | Should -Be (Join-Path $root 'data' 'backlog.md')
        $config.ArchivePath | Should -Be (Join-Path $root 'data' 'done-archive.md')
        $config.DoneKeep | Should -Be 10
    }

    It 'defaults done_keep to 10 and the archive to a sibling of the backlog' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $config = Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.DoneKeep | Should -Be 10
        # A sibling of data/backlog.md, which is where the backlog is - this
        # asserted <root>/done-archive.md while the default resolved to the root
        # file, and that default was the defect.
        $config.ArchivePath | Should -Be (Resolve-FmFullPath -Path (Join-Path $root 'data' 'done-archive.md'))
    }

    It 'still lets a home pin its own path, which is how a Linux-shared home stays legible' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root '.tasks.toml'),
            "backend = `"markdown`"`n`n[markdown]`npath = `"queue/backlog.md`"`n")
        (Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')).Path |
            Should -Be (Resolve-FmFullPath -Path (Join-Path $root 'queue' 'backlog.md'))
    }
}

Describe 'the backlog has ONE location' {
    # THE BUG THIS PINS. `fm-backlog.ps1 add` in a fresh home created
    # <home>/backlog.md, because the resolver probed the root first and fell
    # back to creating it there. Every reader - the session-start digest,
    # cleanup, a Linux firstmate sharing the home - reads <home>/data/backlog.md.
    # So the captain added a work item, firstmate said fine, and startup reported
    # the queue ABSENT. It did not fail; it lost the captain's task queue.

    BeforeAll {
        function New-EmptyHome {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'A Pester fixture builder: it creates a disposable home under TestDrive.')]
            [CmdletBinding()]
            param()
            $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            foreach ($dir in @('data', 'state', 'config', 'projects')) {
                New-Item -ItemType Directory -Path (Join-Path $home_ $dir) -Force | Out-Null
            }
            Resolve-FmFullPath -Path $home_
        }
    }

    It 'is data/backlog.md, and the legacy location is named rather than guessed at' {
        $home_ = New-EmptyHome
        Get-FmBacklogPath -HomePath $home_ | Should -Be (Resolve-FmFullPath -Path (Join-Path $home_ 'data' 'backlog.md'))
        Get-FmBacklogLegacyPath -HomePath $home_ | Should -Be (Resolve-FmFullPath -Path (Join-Path $home_ 'backlog.md'))
    }

    It 'resolves an empty home to data/backlog.md, not to the home root' {
        $home_ = New-EmptyHome
        (Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml')).Path |
            Should -Be (Get-FmBacklogPath -HomePath $home_)
    }

    It 'THE REGRESSION: an added item is found through the path session start reads' {
        # Deliberately end to end and deliberately asymmetric: the item goes in
        # through the command the captain uses, and comes back out through the
        # path the startup digest computes for itself. Before the fix the write
        # went to <home>/backlog.md, this read found nothing, and the digest
        # printed ABSENT.
        $home_ = New-EmptyHome
        $null = Add-FmBacklogTask -Id 'fmwin-demo' -Title 'Ship the morning brief' `
            -Path (Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml')).Path

        $startupPath = Get-FmBacklogPath -HomePath $home_
        Test-Path -LiteralPath $startupPath -PathType Leaf |
            Should -BeTrue -Because 'session start reads exactly this path and reports ABSENT when it is missing'
        Test-Path -LiteralPath (Get-FmBacklogLegacyPath -HomePath $home_) |
            Should -BeFalse -Because 'nothing may still be written to the pre-fix location'
        @(Get-FmBacklog -Path $startupPath).Id | Should -Be 'fmwin-demo'
    }

    It 'migrates a pre-fix root backlog, and its archive, into data/' {
        $home_ = New-EmptyHome
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy, "# Backlog`n`n## Queued`n- [ ] old - the captain's item (since 2026-08-01)`n")
        [System.IO.File]::WriteAllText((Join-Path $home_ 'done-archive.md'), "## Archived 2026-08-01`n- [x] older - done`n")

        $result = Repair-FmBacklogLocation -HomePath $home_ -WarningAction SilentlyContinue
        $result.Action | Should -Be 'migrated'
        $result.ArchiveMoved | Should -BeTrue
        $result.Message | Should -BeLike "*moved the backlog from $legacy*"
        Test-Path -LiteralPath $legacy | Should -BeFalse
        @(Get-FmBacklog -Path (Get-FmBacklogPath -HomePath $home_)).Id | Should -Be 'old'
        Test-Path -LiteralPath (Join-Path $home_ 'data' 'done-archive.md') | Should -BeTrue
    }

    It 'migrates on the next backlog command, so items are never orphaned by the fix' {
        $home_ = New-EmptyHome
        [System.IO.File]::WriteAllText((Get-FmBacklogLegacyPath -HomePath $home_),
            "# Backlog`n`n## Queued`n- [ ] old - the captain's item (since 2026-08-01)`n")
        $config = Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml') `
            -WarningAction SilentlyContinue
        $config.Path | Should -Be (Get-FmBacklogPath -HomePath $home_)
        @(Get-FmBacklog -Path $config.Path).Id | Should -Be 'old'
    }

    It 'is a no-op in a home that never had one, and idempotent after a migration' {
        $home_ = New-EmptyHome
        (Repair-FmBacklogLocation -HomePath $home_).Action | Should -Be 'none'
        [System.IO.File]::WriteAllText((Get-FmBacklogLegacyPath -HomePath $home_), "# Backlog`n")
        (Repair-FmBacklogLocation -HomePath $home_ -WarningAction SilentlyContinue).Action | Should -Be 'migrated'
        (Repair-FmBacklogLocation -HomePath $home_).Action | Should -Be 'none'
    }

    It 'moves nothing under -WhatIf' {
        $home_ = New-EmptyHome
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy, "# Backlog`n")
        (Repair-FmBacklogLocation -HomePath $home_ -WhatIf).Action | Should -Be 'none'
        Test-Path -LiteralPath $legacy | Should -BeTrue
    }

    It 'REFUSES when both files hold a queue, naming both and merging neither' {
        $home_ = New-EmptyHome
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        $canonical = Get-FmBacklogPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy, "# Backlog`n`n## Queued`n- [ ] a - one`n")
        [System.IO.File]::WriteAllText($canonical, "# Backlog`n`n## Queued`n- [ ] b - two`n")

        $result = Repair-FmBacklogLocation -HomePath $home_
        $result.Action | Should -Be 'conflict'
        $result.Message | Should -BeLike "*$legacy*"
        $result.Message | Should -BeLike "*$canonical*"
        { Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml') } |
            Should -Throw '*two backlogs in this home*'
        # Neither file was touched: which items are current is the captain's call.
        [System.IO.File]::ReadAllText($legacy) | Should -Match ([regex]::Escape('- [ ] a - one'))
        [System.IO.File]::ReadAllText($canonical) | Should -Match ([regex]::Escape('- [ ] b - two'))
    }

    It 'refuses to move a legacy backlog another process holds the lock on' {
        $home_ = New-EmptyHome
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy, "# Backlog`n")
        [System.IO.File]::WriteAllText("$legacy.lock", "12345:abc:1`n")
        $result = Repair-FmBacklogLocation -HomePath $home_
        $result.Action | Should -Be 'conflict'
        $result.Message | Should -BeLike '*locked by another process*'
        Test-Path -LiteralPath $legacy | Should -BeTrue
    }

    It 'never starts an empty queue beside a real one: the root file MOVES, it is not left behind' {
        # The alternative fix considered for this defect - search data/ first but
        # keep <home>/backlog.md as a second candidate - is deliberately NOT what
        # this port does, and this pins the difference.
        #
        # Keeping the root candidate fixes a FRESH home and leaves an
        # already-split one split: the resolver would go on reading
        # <home>/backlog.md while the session-start digest, cleanup and a Linux
        # firstmate sharing the home read data/backlog.md unconditionally, so the
        # captain's own home - the one the defect was found on - would still
        # report the queue ABSENT with their items in it.
        #
        # The concern behind that alternative is real and is met here in full: no
        # empty file is created next to the captain's items. Their file is the one
        # that ends up at the canonical path, with its items intact.
        $home_ = New-EmptyHome
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy,
            "# Backlog`n`n## Queued`n- [ ] keep-me - the captain's item (since 2026-08-01)`n")

        $config = Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml') `
            -WarningAction SilentlyContinue

        $config.Path | Should -Be (Get-FmBacklogPath -HomePath $home_)
        @(Get-FmBacklog -Path $config.Path).Id |
            Should -Be 'keep-me' -Because 'the existing queue moved; a new empty one was never created'
        Test-Path -LiteralPath $legacy |
            Should -BeFalse -Because 'leaving it behind is exactly the split that made the digest report ABSENT'
        # And the path every other reader computes for itself now agrees.
        Test-Path -LiteralPath (Get-FmBacklogPath -HomePath $home_) -PathType Leaf | Should -BeTrue
    }

    It 'leaves a home that deliberately pins another path alone' {
        # A pinned backlog is not the pre-fix accident, and moving a file the
        # home never named would be the surprise. It is also the escape hatch for
        # the one legitimate root-level layout - tasks-axi's own default shape -
        # so a home that really wants its queue at the root says so and keeps it.
        $home_ = New-EmptyHome
        [System.IO.File]::WriteAllText((Join-Path $home_ '.tasks.toml'),
            "backend = `"markdown`"`n`n[markdown]`npath = `"data/elsewhere.md`"`n")
        $legacy = Get-FmBacklogLegacyPath -HomePath $home_
        [System.IO.File]::WriteAllText($legacy, "# Backlog`n")
        $config = Get-FmBacklogConfig -Root $home_ -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.Path | Should -Be (Resolve-FmFullPath -Path (Join-Path $home_ 'data' 'elsewhere.md'))
        Test-Path -LiteralPath $legacy | Should -BeTrue
    }

    It 'ignores comments and unsupported tables' {
        $config = ConvertFrom-FmBacklogConfigToml -Text "# a comment`nbackend = `"markdown`" # trailing`n[other]`nnonsense = 1`n"
        $config.Backend | Should -Be 'markdown'
    }

    It 'refuses a malformed line, an unterminated string and a non-integer done_keep' {
        { ConvertFrom-FmBacklogConfigToml -Text "nonsense`n" } | Should -Throw '*key = value*'
        { ConvertFrom-FmBacklogConfigToml -Text "backend = `"markdown`n" } | Should -Throw '*unterminated*'
        { ConvertFrom-FmBacklogConfigToml -Text "[markdown]`ndone_keep = `"ten`"`n" } | Should -Throw '*integer*'
    }
}

Describe 'bin/fm-backlog.ps1' {
    BeforeAll { $script:entry = Join-Path $script:RepoRoot 'bin' 'fm-backlog.ps1' }

    It 'exits 2 with usage when no command is given' {
        $stderr = Join-Path $TestDrive 'usage.err'
        pwsh -NoProfile -File $script:entry 2>$stderr | Out-Null
        $LASTEXITCODE | Should -Be 2
        (Get-Content -Raw -LiteralPath $stderr) | Should -Match 'usage: fm-backlog.ps1'
    }

    It 'exits 2 on an unknown command' {
        pwsh -NoProfile -File $script:entry 'frobnicate' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'exits 1 and prints a plain refusal line for a refused mutation' {
        $path = New-BacklogFile
        $stderr = Join-Path $TestDrive 'refuse.err'
        pwsh -NoProfile -File $script:entry 'start' 'ghost' -Path $path 2>$stderr | Out-Null
        $LASTEXITCODE | Should -Be 1
        $text = Get-Content -Raw -LiteralPath $stderr
        $text | Should -Match 'not found'
        $text | Should -Not -Match 'ScriptStackTrace|At line'
    }

    It 'lists and mutates through the module' {
        $path = New-BacklogFile
        $out = pwsh -NoProfile -File $script:entry 'ready' -Path $path
        $LASTEXITCODE | Should -Be 0
        $out = pwsh -NoProfile -File $script:entry 'add' 'task-d' 'a new item' -Path $path
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'add task-d -> queued'
        (Get-FmBacklogTask -Id 'task-d' -Path $path).Title | Should -Be 'a new item'
    }
}

Describe 'differential parity with the tasks-axi markdown backend' {
    # Resolved at DISCOVERY time: -Skip is evaluated while the tests are being
    # discovered, long before any BeforeAll has run.
    BeforeDiscovery {
        $script:HasTasksAxi = $null -ne (Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)
    }
    BeforeAll {
        $script:axi = Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    It 'produces a byte-identical backlog and archive for the same mutation sequence' -Skip:(-not $script:HasTasksAxi) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $axiPath = New-BacklogFile
        $psPath = New-BacklogFile

        & $script:axi.Source 'add' 'task-d' 'new thing' '--repo' 'alpha' '--file' $axiPath | Out-Null
        & $script:axi.Source 'start' 'task-d' '--file' $axiPath | Out-Null
        & $script:axi.Source 'done' 'task-d' '--note' 'shipped' '--keep' '1' '--file' $axiPath | Out-Null
        & $script:axi.Source 'hold' 'task-c' '--reason' 'waiting for upstream' '--kind' 'external' '--file' $axiPath | Out-Null
        & $script:axi.Source 'block' 'task-b' '--by' 'task-a' '--file' $axiPath | Out-Null

        $null = Add-FmBacklogTask -Id 'task-d' -Title 'new thing' -Repo 'alpha' -Path $psPath -Date $today
        $null = Start-FmBacklogTask -Id 'task-d' -Path $psPath -Date $today
        $null = Complete-FmBacklogTask -Id 'task-d' -Note 'shipped' -Keep 1 -Path $psPath -Date $today
        $null = Set-FmBacklogHold -Id 'task-c' -Reason 'waiting for upstream' -Kind external -Path $psPath
        $null = Block-FmBacklogTask -Id 'task-b' -By 'task-a' -Path $psPath

        Get-Text -Path $psPath | Should -Be (Get-Text -Path $axiPath)
        $axiArchive = Join-Path (Split-Path -Parent $axiPath) 'done-archive.md'
        $psArchive = Join-Path (Split-Path -Parent $psPath) 'done-archive.md'
        Get-Text -Path $psArchive | Should -Be (Get-Text -Path $axiArchive)
    }

    It 'reads back a file tasks-axi wrote with identical field values' -Skip:(-not $script:HasTasksAxi) {
        $path = New-BacklogFile
        & $script:axi.Source 'add' 'task-d' 'from the tool' '--repo' 'gamma' '--kind' 'captain' '--file' $path | Out-Null
        & $script:axi.Source 'hold' 'task-d' '--reason' 'captain decision pending' '--kind' 'captain' '--file' $path | Out-Null
        $task = Get-FmBacklogTask -Id 'task-d' -Path $path
        $task.Repo | Should -Be 'gamma'
        $task.Kind | Should -Be 'captain'
        $task.Hold.Reason | Should -Be 'captain decision pending'
        $task.Hold.Kind | Should -Be 'captain'
        (Get-Ids (Get-FmBacklogReady -Path $path)) | Should -Not -Match 'task-d'
    }
}
