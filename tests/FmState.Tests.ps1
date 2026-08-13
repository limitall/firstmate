#requires -Version 7.0
<#
    Tests for Private/FmState.ps1 - state file reads and writes.

    This is the adversarial suite for the port's highest-risk file. It covers
    three separate things, and all three matter:

      1. THE BYTE CONTRACT. A Linux firstmate and this one must read each other's
         files, so the tests assert on raw BYTES, not on round-tripping through
         our own reader - a reader and writer that share a mistake round-trip
         perfectly and are still wrong.

      2. THE RETRY DISCIPLINE. The sharing violations this exists for happen on
         Windows, not here, so the retry engine is driven directly with injected
         exceptions rather than inferred from a race that Linux will not produce.

      3. REAL CONCURRENCY. Separate processes hammering one file, proving that
         appends do not interleave and that a reader never sees a half-published
         file. That much reproduces honestly on this platform.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    Import-FmTestModule -TestRoot $PSScriptRoot
    $script:ModulePath = (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1')
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fmstate-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force

    function Get-TestPath {
        param([string]$Name = 'record')
        Join-Path $script:TempRoot ("$Name-" + [guid]::NewGuid().ToString('N'))
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The on-disk byte contract' {
    It 'writes UTF-8 with no byte order mark' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'window=fm:1'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # A BOM would corrupt the first field of the first line for every bash reader.
        $bytes[0] | Should -Be 0x77   # 'w'
        $bytes.Length | Should -Be 12
    }

    It 'writes LF line endings, never CRLF' {
        $path = Get-TestPath
        Write-FmStateLines -Path $path -Line @('window=fm:1', 'harness=claude')
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # Set-Content and Out-File would write CRLF on Windows. Nothing here uses them.
        $bytes | Should -Not -Contain 0x0D
        ($bytes | Where-Object { $_ -eq 0x0A }).Count | Should -Be 2
    }

    It 'ends a line-oriented file with a trailing LF, like printf %s\n' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'done: PR https://example/pr/1'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[-1] | Should -Be 0x0A
    }

    It 'does not add a second newline to content that already ends with one' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content "a`n"
        [System.IO.File]::ReadAllBytes($path).Length | Should -Be 2
    }

    It 'normalizes CRLF input to LF on the way out' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content "a`r`nb`r`n"
        [System.IO.File]::ReadAllBytes($path) | Should -Not -Contain 0x0D
    }

    It 'suppresses the trailing newline on request' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'no-newline' -NoTrailingNewline
        [System.IO.File]::ReadAllBytes($path)[-1] | Should -Be 0x65   # 'e'
    }

    It 'writes an empty file for empty content, with no stray newline' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content ''
        [System.IO.File]::ReadAllBytes($path).Length | Should -Be 0
    }

    It 'round-trips non-ASCII text as UTF-8' {
        # Built from code points so this test file stays pure ASCII and the
        # assertion tests the module's encoding, not the test file's.
        $path = Get-TestPath
        $text = 'note=caf' + [char]0x00E9 + ' ' + [char]0x2693
        Write-FmStateFile -Path $path -Content $text
        Read-FmStateFile -Path $path | Should -Be "$text`n"
        [System.IO.File]::ReadAllBytes($path) | Should -Contain 0xC3   # UTF-8 lead byte
    }
}

Describe 'Reading' {
    It 'returns $null for a file that does not exist' {
        # Missing is an answer, not an error - `cat 2>/dev/null` in the original.
        Read-FmStateFile -Path (Get-TestPath) | Should -BeNullOrEmpty
    }

    It 'distinguishes an empty file from a missing one' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content ''
        $result = Read-FmStateFile -Path $path
        $null -eq $result | Should -BeFalse
        $result | Should -Be ''
    }

    It 'returns an empty collection of lines for a missing file' {
        (Read-FmStateLines -Path (Get-TestPath)).Count | Should -Be 0
    }

    It 'drops only the final newline, keeping meaningful blank lines inside' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content "a`n`nb`n"
        $lines = Read-FmStateLines -Path $path
        $lines.Count | Should -Be 3
        $lines[1] | Should -Be ''
    }

    It 'tolerates a CRLF file written by some other tool' {
        $path = Get-TestPath
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::UTF8.GetBytes("a`r`nb`r`n"))
        Read-FmStateLines -Path $path | Should -Be @('a', 'b')
    }

    It 'strips a BOM it would never write itself' {
        $path = Get-TestPath
        $bom = [byte[]]@(0xEF, 0xBB, 0xBF)
        [System.IO.File]::WriteAllBytes($path, $bom + [System.Text.Encoding]::UTF8.GetBytes("window=fm:1`n"))
        Read-FmStateLines -Path $path | Should -Be @('window=fm:1')
    }
}

Describe 'Appending' {
    It 'creates the file and its directory on first append' {
        $path = Join-Path (Get-TestPath 'deep') 'nested' 'task.status'
        Add-FmStateLine -Path $path -Line 'working: setup done'
        Read-FmStateLines -Path $path | Should -Be @('working: setup done')
    }

    It 'appends rather than replacing - the status log is append-only' {
        $path = Get-TestPath 'status'
        Add-FmStateLine -Path $path -Line 'working: setup done'
        Add-FmStateLine -Path $path -Line 'done: PR https://example/pr/1'
        Read-FmStateLines -Path $path | Should -HaveCount 2
    }

    It 'appends several lines in one call' {
        $path = Get-TestPath 'status'
        Add-FmStateLine -Path $path -Line @('a', 'b', 'c')
        Read-FmStateLines -Path $path | Should -Be @('a', 'b', 'c')
    }

    It 'refuses a line containing a newline instead of silently writing two records' {
        # A smuggled newline splits into two records for every reader, durably.
        $path = Get-TestPath 'status'
        { Add-FmStateLine -Path $path -Line "done: ok`nblocked: no" } | Should -Throw '*line feed*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'refuses a line containing a carriage return' {
        { Add-FmStateLine -Path (Get-TestPath) -Line "done: ok`r" } | Should -Throw '*carriage return*'
    }
}

Describe 'Atomic publication' {
    It 'leaves no temp file behind after a successful write' {
        $path = Join-Path $script:TempRoot ('atomic-' + [guid]::NewGuid().ToString('N'))
        Write-FmStateFile -Path $path -Content 'a'
        $name = [System.IO.Path]::GetFileName($path)
        @(Get-ChildItem -LiteralPath $script:TempRoot -Filter ".$name.tmp.*" -Force).Count | Should -Be 0
    }

    It 'cleans up its temp file and leaves the destination untouched when publication fails' {
        # A directory at the destination makes the move fail deterministically -
        # the closest reproducible stand-in for a Windows sharing violation that
        # outlives the retry budget.
        $path = Join-Path $script:TempRoot ('blocked-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path -Force
        $marker = Join-Path $path 'inside.txt'
        Set-Content -LiteralPath $marker -Value 'untouched' -NoNewline

        { Write-FmStateFile -Path $path -Content 'new' -ErrorAction Stop } | Should -Throw
        Get-Content -LiteralPath $marker -Raw | Should -Be 'untouched'
        $name = [System.IO.Path]::GetFileName($path)
        @(Get-ChildItem -LiteralPath $script:TempRoot -Filter ".$name.tmp.*" -Force).Count | Should -Be 0
    }

    It 'replaces content wholesale rather than truncating in place' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content ('x' * 500)
        Write-FmStateFile -Path $path -Content 'short'
        Read-FmStateFile -Path $path | Should -Be "short`n"
    }
}

Describe 'key=value records' {
    It 'parses fields in file order' {
        $path = Get-TestPath 'meta'
        Write-FmStateFile -Path $path -Content "window=fm:1`nharness=claude`n"
        $fields = Read-FmKeyValueFile -Path $path
        @($fields.Keys) | Should -Be @('window', 'harness')
        $fields['harness'] | Should -Be 'claude'
    }

    It 'splits on the first = only, so a value keeps its own = signs' {
        $path = Get-TestPath 'meta'
        Write-FmStateFile -Path $path -Content "pr=https://x/y?a=b&c=d`n"
        (Read-FmKeyValueFile -Path $path)['pr'] | Should -Be 'https://x/y?a=b&c=d'
    }

    It 'ignores a line with no = at all, as the bash readers do' {
        $path = Get-TestPath 'meta'
        Write-FmStateFile -Path $path -Content "window=fm:1`ngarbage`n"
        (Read-FmKeyValueFile -Path $path).Count | Should -Be 1
    }

    It 'takes the last value for a duplicated key' {
        $path = Get-TestPath 'meta'
        Write-FmStateFile -Path $path -Content "mode=no-mistakes`nmode=direct-PR`n"
        (Read-FmKeyValueFile -Path $path)['mode'] | Should -Be 'direct-PR'
    }

    It 'returns an empty map, not $null, for a missing record' {
        (Read-FmKeyValueFile -Path (Get-TestPath)).Count | Should -Be 0
    }

    It 'preserves the caller field order when writing' {
        $path = Get-TestPath 'meta'
        Write-FmKeyValueFile -Path $path -Fields ([ordered]@{
                window = 'fm:1'; endpoint_task_id = 't1'; harness = 'claude'
            })
        Read-FmStateLines -Path $path | Should -Be @('window=fm:1', 'endpoint_task_id=t1', 'harness=claude')
    }

    It 'refuses a field value containing a newline' {
        { Write-FmKeyValueFile -Path (Get-TestPath) -Fields ([ordered]@{ a = "x`ny=2" }) } |
            Should -Throw '*line feed*'
    }

    It 'refuses a field name containing = or whitespace' {
        { Write-FmKeyValueFile -Path (Get-TestPath) -Fields ([ordered]@{ 'a=b' = 'x' }) } | Should -Throw
        { Write-FmKeyValueFile -Path (Get-TestPath) -Fields ([ordered]@{ 'a b' = 'x' }) } | Should -Throw
    }
}

Describe 'Set-FmKeyValueField' {
    BeforeEach {
        $script:Meta = Get-TestPath 'meta'
        Write-FmStateFile -Path $script:Meta -Content "window=fm:1`nproject=/p/a`nharness=claude`n"
    }

    It 'replaces a field in place, keeping field order stable' {
        Set-FmKeyValueField -Path $script:Meta -Name 'project' -Value '/p/b'
        Read-FmStateLines -Path $script:Meta |
            Should -Be @('window=fm:1', 'project=/p/b', 'harness=claude')
    }

    It 'appends a field that does not exist yet' {
        Set-FmKeyValueField -Path $script:Meta -Name 'pr' -Value 'https://example/pr/1'
        (Read-FmStateLines -Path $script:Meta)[-1] | Should -Be 'pr=https://example/pr/1'
    }

    It 'removes a field' {
        Set-FmKeyValueField -Path $script:Meta -Name 'harness' -Remove
        (Read-FmKeyValueFile -Path $script:Meta).Contains('harness') | Should -BeFalse
        (Read-FmStateLines -Path $script:Meta).Count | Should -Be 2
    }

    It 'carries through fields written by another tool untouched' {
        # This is what makes it safe against a record whose full schema this port
        # does not own - fm-spawn writes backend-specific fields we never parse.
        Add-FmStateLine -Path $script:Meta -Line 'orca_worktree_id=abc123'
        Set-FmKeyValueField -Path $script:Meta -Name 'window' -Value 'fm:2'
        (Read-FmKeyValueFile -Path $script:Meta)['orca_worktree_id'] | Should -Be 'abc123'
    }

    It 'collapses duplicates of the target key to one' {
        Add-FmStateLine -Path $script:Meta -Line 'project=/p/dup'
        Set-FmKeyValueField -Path $script:Meta -Name 'project' -Value '/p/final'
        @(Read-FmStateLines -Path $script:Meta | Where-Object { $_ -like 'project=*' }) |
            Should -Be @('project=/p/final')
    }

    It 'creates the record when it does not exist yet' {
        $fresh = Get-TestPath 'meta'
        Set-FmKeyValueField -Path $fresh -Name 'window' -Value 'fm:1'
        Read-FmStateLines -Path $fresh | Should -Be @('window=fm:1')
    }

    It 'matches field names case-sensitively, like grep ^key=' {
        Set-FmKeyValueField -Path $script:Meta -Name 'Project' -Value '/p/other'
        (Read-FmKeyValueFile -Path $script:Meta)['project'] | Should -Be '/p/a'
        (Read-FmKeyValueFile -Path $script:Meta)['Project'] | Should -Be '/p/other'
    }
}

Describe 'File age' {
    It 'reports a fresh file as seconds old' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'x'
        Get-FmPathAge -Path $path | Should -BeLessThan 5
    }

    It 'reports the sentinel age for a missing path, so it never reads as fresh' {
        # fm_path_age's 999999 contract: an unreadable path must compare as very
        # old against every threshold, never as brand new.
        Get-FmPathAge -Path (Get-TestPath) | Should -Be 999999
    }

    It 'reads an age from a backdated file' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'x'
        [System.IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddSeconds(-90))
        Get-FmPathAge -Path $path | Should -BeGreaterOrEqual 89
    }

    It 'clamps a future timestamp to zero rather than reporting a negative age' {
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'x'
        [System.IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddHours(1))
        Get-FmPathAge -Path $path | Should -Be 0
    }

    It 'returns $null mtime for a missing path' {
        Get-FmPathMtime -Path (Get-TestPath) | Should -BeNullOrEmpty
    }
}

Describe 'Retry discipline' {
    It 'classifies a plain IOException as transient - a sharing violation is one' {
        InModuleScope Firstmate {
            Test-FmTransientIOException -Exception ([System.IO.IOException]::new('busy')) | Should -BeTrue
        }
    }

    It 'classifies UnauthorizedAccessException as transient - a file pending delete raises it' {
        InModuleScope Firstmate {
            Test-FmTransientIOException -Exception ([System.UnauthorizedAccessException]::new()) | Should -BeTrue
        }
    }

    It 'classifies <Type> as permanent, despite deriving from IOException' -ForEach @(
        @{ Type = 'FileNotFoundException' }
        @{ Type = 'DirectoryNotFoundException' }
        @{ Type = 'PathTooLongException' }
    ) {
        InModuleScope Firstmate -Parameters @{ Type = $Type } {
            $exception = New-Object "System.IO.$Type"
            Test-FmTransientIOException -Exception $exception | Should -BeFalse
        }
    }

    It 'looks inside the wrapper PowerShell puts around a .NET call' {
        InModuleScope Firstmate {
            $wrapped = [System.Management.Automation.MethodInvocationException]::new(
                'call failed', [System.IO.IOException]::new('sharing violation'))
            Test-FmTransientIOException -Exception $wrapped | Should -BeTrue
        }
    }

    It 'treats an unrelated exception as permanent' {
        InModuleScope Firstmate {
            Test-FmTransientIOException -Exception ([System.ArgumentException]::new('bad')) | Should -BeFalse
        }
    }

    It 'retries a transient failure and returns the eventual success' {
        InModuleScope Firstmate {
            $script:Attempts = 0
            $result = Invoke-FmFileRetry -Operation 'test' -Path 'x' -DelayMilliseconds 1 -MaxDelayMilliseconds 2 -Action {
                $script:Attempts++
                if ($script:Attempts -lt 3) { throw [System.IO.IOException]::new('sharing violation') }
                'published'
            }
            $result | Should -Be 'published'
            $script:Attempts | Should -Be 3
        }
    }

    It 'counts the retries it performed' {
        InModuleScope Firstmate {
            $before = $script:FmStateRetryTotal
            $script:Attempts = 0
            $null = Invoke-FmFileRetry -Operation 'test' -DelayMilliseconds 1 -MaxDelayMilliseconds 2 -Action {
                $script:Attempts++
                if ($script:Attempts -lt 3) { throw [System.IO.IOException]::new('busy') }
                'ok'
            }
            ($script:FmStateRetryTotal - $before) | Should -Be 2
        }
    }

    It 'does not retry a permanent failure - it fails in one attempt' {
        InModuleScope Firstmate {
            $script:Attempts = 0
            {
                Invoke-FmFileRetry -Operation 'test' -DelayMilliseconds 1 -Action {
                    $script:Attempts++
                    throw [System.IO.FileNotFoundException]::new('gone')
                }
            } | Should -Throw
            $script:Attempts | Should -Be 1
        }
    }

    It 'gives up after the budget and names the operation, path and attempts' {
        InModuleScope Firstmate {
            $script:Attempts = 0
            {
                Invoke-FmFileRetry -Operation 'read state file' -Path '/x/y' -Attempts 3 `
                    -DelayMilliseconds 1 -MaxDelayMilliseconds 2 -Action {
                    $script:Attempts++
                    throw [System.IO.IOException]::new('sharing violation')
                }
            } | Should -Throw '*read state file failed after 3 attempts on ''/x/y''*'
            $script:Attempts | Should -Be 3
        }
    }

    It 'takes its budget from the environment' {
        InModuleScope Firstmate {
            $saved = $env:FM_STATE_RETRY_ATTEMPTS
            try {
                $env:FM_STATE_RETRY_ATTEMPTS = '2'
                Get-FmStateRetrySetting -Name 'Attempts' | Should -Be 2
                $env:FM_STATE_RETRY_ATTEMPTS = 'nonsense'
                Get-FmStateRetrySetting -Name 'Attempts' | Should -Be 12
            } finally {
                $env:FM_STATE_RETRY_ATTEMPTS = $saved
            }
        }
    }

    It 'retries a genuinely locked file on Windows' -Skip:(-not $IsWindows) {
        # WINDOWS-UNVERIFIED: FileShare.None only blocks other openers on
        # Windows; on Linux .NET does not enforce it, so this cannot run here.
        $path = Get-TestPath
        Write-FmStateFile -Path $path -Content 'held'
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $saved = $env:FM_STATE_RETRY_ATTEMPTS
            $env:FM_STATE_RETRY_ATTEMPTS = '2'
            try { { Read-FmStateFile -Path $path } | Should -Throw '*after 2 attempts*' }
            finally { $env:FM_STATE_RETRY_ATTEMPTS = $saved }
        } finally { $stream.Dispose() }
    }
}

Describe 'Real concurrency across processes' {
    It 'loses no line when several processes append to one status log' {
        $path = Join-Path $script:TempRoot ('concurrent-' + [guid]::NewGuid().ToString('N') + '.status')
        $writers = 3
        $perWriter = 40
        $jobs = 1..$writers | ForEach-Object {
            Start-Job -ArgumentList $script:ModulePath, $path, $_, $perWriter -ScriptBlock {
                param($ModulePath, $Path, $Writer, $Count)
                Import-Module $ModulePath -Force
                for ($i = 1; $i -le $Count; $i++) {
                    Add-FmStateLine -Path $Path -Line "working: writer $Writer line $i"
                }
            }
        }
        $null = $jobs | Wait-Job -Timeout 180
        # Read the writers' own outcome BEFORE the file. A writer that threw -
        # Add-FmStateLine gives up on the append lock after its timeout - or that
        # was still running at the deadline leaves exactly the same evidence
        # downstream as a lost line, and only one of those is a defect in the
        # append. Name which one it was rather than letting the count assertion
        # report a lock timeout as data loss.
        # Collect the reason WITH the state. Reporting them as separate
        # assertions loses the diagnosis: Pester stops an It at the first
        # failure, so when a writer died the run printed "13:Failed" and never
        # reached the line that would have said what it threw. That is exactly
        # what came back from the Windows 11 laptop, and it cost a round trip -
        # the failure has to carry its own cause, because the machine that can
        # reproduce it is not the machine this suite usually runs on.
        $writerErrors = @($jobs | ForEach-Object { $_.ChildJobs[0].Error } |
            ForEach-Object { [string]$_ })
        $unfinished = @($jobs | Where-Object { $_.State -ne 'Completed' } |
            ForEach-Object {
                $why = @($_.ChildJobs[0].Error | ForEach-Object { [string]$_ }) -join ' | '
                if (-not $why) { $why = '(no error recorded - still running at the deadline)' }
                "$($_.Id):$($_.State): $why"
            })
        $jobs | Remove-Job -Force
        $unfinished | Should -BeNullOrEmpty -Because 'every writer must finish before the file is judged'
        $writerErrors | Should -BeNullOrEmpty -Because 'a writer that threw did not lose a line, it never wrote one'

        $lines = Read-FmStateLines -Path $path
        $lines.Count | Should -Be ($writers * $perWriter)
        # Every line intact: no truncation, and no two appends interleaved into
        # one corrupt record.
        @($lines | Where-Object { $_ -notmatch '^working: writer [0-9]+ line [0-9]+$' }).Count | Should -Be 0
        1..$writers | ForEach-Object {
            $writer = $_
            @($lines | Where-Object { $_ -like "working: writer $writer line *" }).Count | Should -Be $perWriter
        }
    }

    It 'answers null, not an exception, when a file vanishes mid-read' {
        # THE DEFECT THIS PINS. Read-FmStateFile checked File.Exists and then
        # opened the file, and a delete landing between the two threw
        # FileNotFoundException straight out of a reader whose whole contract is
        # "missing is the answer". It is not a theoretical window: a lock holder
        # releasing its lock deletes pid-identity while another process is
        # inspecting that same lock, which killed the inspecting process's
        # append and LOST the line it was writing (measured: 8 escapes per run
        # of this loop before the fix, 0 after; and roughly one in three runs of
        # the append test above failed on it).
        $dir = Join-Path $script:TempRoot ('vanish-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $file = Join-Path $dir 'pid-identity'

        $churn = Start-Job -ArgumentList $file -ScriptBlock {
            param($File)
            for ($i = 0; $i -lt 400; $i++) {
                [System.IO.File]::WriteAllText($File, "identity $i")
                [System.IO.File]::Delete($File)
            }
        }
        try {
            $thrown = @()
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while ($churn.State -eq 'Running' -and [datetime]::UtcNow -lt $deadline) {
                try { $null = Read-FmStateFile -Path $file }
                catch { $thrown += [string]$_ }
            }
            $null = $churn | Wait-Job -Timeout 60
            $thrown | Should -BeNullOrEmpty -Because 'a file that is gone is an answer, not a failure'
        }
        finally {
            $churn | Remove-Job -Force
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'never shows a reader a half-published file' {
        $path = Join-Path $script:TempRoot ('publish-' + [guid]::NewGuid().ToString('N') + '.meta')
        $short = 'window=fm:1'
        $long = 'window=fm:1' + ('9' * 4000)
        Write-FmStateFile -Path $path -Content $short

        $writer = Start-Job -ArgumentList $script:ModulePath, $path, $short, $long -ScriptBlock {
            param($ModulePath, $Path, $Short, $Long)
            Import-Module $ModulePath -Force
            for ($i = 0; $i -lt 150; $i++) {
                Write-FmStateFile -Path $Path -Content $(if ($i % 2) { $Long } else { $Short })
            }
        }
        try {
            $observed = [System.Collections.Generic.HashSet[string]]::new()
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while ($writer.State -eq 'Running' -and [datetime]::UtcNow -lt $deadline) {
                $content = Read-FmStateFile -Path $path
                if ($null -ne $content) { $null = $observed.Add($content) }
            }
            $null = $writer | Wait-Job -Timeout 60
            # Only whole values are ever observable: anything else means a reader
            # caught a partially written file.
            foreach ($value in $observed) {
                $value | Should -BeIn @("$short`n", "$long`n")
            }
            $observed.Count | Should -BeGreaterThan 0
        } finally {
            $writer | Remove-Job -Force
        }
    }
}
