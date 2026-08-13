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
        $config.ArchivePath | Should -Be (Join-Path $root 'data' 'done-archive.md')
    }

    It 'defaults a home with no backlog yet to data/backlog.md, the file the rest of firstmate reads' {
        # The regression this pins: the default used to be <root>/backlog.md, so
        # the very first `fm-backlog add` in a fresh home wrote a queue that the
        # session-start digest, teardown and a Linux firstmate never look at.
        # Nothing errored - the items simply went somewhere unread.
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $config = Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.Path | Should -Be (Join-Path $root 'data' 'backlog.md')
    }

    It 'prefers data/backlog.md over a root copy when both exist' {
        # Order matters as much as the default: once a root copy existed it used
        # to win every later lookup, which is what made the split permanent.
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'data') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'backlog.md'), "# Backlog`n")
        [System.IO.File]::WriteAllText((Join-Path $root 'data' 'backlog.md'), "# Backlog`n")
        $config = Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.Path | Should -Be (Join-Path $root 'data' 'backlog.md')
    }

    It 'still finds an existing root backlog.md rather than starting an empty one beside it' {
        # A home that already carries the tasks-axi default shape keeps working:
        # the fix changes where a NEW queue is created, never which existing file
        # is read.
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'backlog.md'), "# Backlog`n")
        $config = Get-FmBacklogConfig -Root $root -HomeConfigPath (Join-Path $TestDrive 'absent.toml')
        $config.Path | Should -Be (Join-Path $root 'backlog.md')
        $config.ArchivePath | Should -Be (Join-Path $root 'done-archive.md')
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
