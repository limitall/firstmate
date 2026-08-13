#requires -Version 7.0
<#
    Tests for Private/FmIdentity.ps1 - process identity, liveness, and the
    harness ancestry walk.

    Two properties matter more than the rest and are tested hardest:
      - a recycled process id must never be mistaken for the original, and
      - every uncertain answer must fail SAFE, reporting a process ALIVE, because
        a wrong "dead" lets a caller steal a live session's lock.

    The ancestry walk is tested against a synthetic process tree rather than the
    real one: the real tree differs on every machine, and the rules being tested
    (stop at the first non-harness ancestor, extend only through a contiguous
    Claude run) are precisely the ones a real tree will not reliably exhibit.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    Import-FmTestModule -TestRoot $PSScriptRoot
    # A pid far above any plausible live process, used as "definitely not running".
    $script:DeadPid = 2147483600
}

Describe 'Get-FmProcessIdentity' {
    It 'returns a token for a live process' {
        Get-FmProcessIdentity -Id $PID | Should -Not -BeNullOrEmpty
    }

    It 'is stable across calls for the same process' {
        Get-FmProcessIdentity -Id $PID | Should -Be (Get-FmProcessIdentity -Id $PID)
    }

    It 'is a single line with no tab, so it survives a state file round trip' {
        Get-FmProcessIdentity -Id $PID | Should -Not -Match "[`t`r`n]"
    }

    It 'pins the process creation time, so a recycled id cannot match' {
        Get-FmProcessIdentity -Id $PID | Should -Match '^[a-z-]*starttime[a-z-]*=[0-9]+ name=.+$'
    }

    It 'reads the same for a process as for an observer of that process' {
        # The regression test for the defect that broke mutual exclusion: a
        # process records its identity into a lock and a DIFFERENT process
        # compares it later, so a token that differs by who is asking makes every
        # live holder look like a recycled process id. Get-Process's StartTime on
        # Linux does exactly that, being re-derived from a re-rounded boot time.
        $module = (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1')
        $job = Start-Job -ArgumentList $module -ScriptBlock {
            param($ModulePath)
            Import-Module $ModulePath -Force
            [pscustomobject]@{ ProcessId = $PID; Identity = (Get-FmProcessIdentity -Id $PID) }
            Start-Sleep -Seconds 30
        }
        try {
            $reported = $null
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while (-not $reported -and [datetime]::UtcNow -lt $deadline) {
                $reported = $job | Receive-Job | Select-Object -First 1
                if (-not $reported) { Start-Sleep -Milliseconds 100 }
            }
            $reported | Should -Not -BeNullOrEmpty
            Get-FmProcessIdentity -Id $reported.ProcessId | Should -Be $reported.Identity
        } finally {
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'differs between two different processes' {
        $other = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 5' -PassThru
        try {
            Get-FmProcessIdentity -Id $other.Id | Should -Not -Be (Get-FmProcessIdentity -Id $PID)
        } finally {
            $other | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null for a process that does not exist' {
        Get-FmProcessIdentity -Id $script:DeadPid | Should -BeNullOrEmpty
    }

    It 'returns $null rather than a partial token for a malformed id' -ForEach @(
        @{ Value = '' }, @{ Value = 'abc' }, @{ Value = '-1' }, @{ Value = '12x' }, @{ Value = $null }
    ) {
        Get-FmProcessIdentity -Id $Value | Should -BeNullOrEmpty
    }
}

Describe 'Test-FmProcessAlive' {
    It 'reports this process alive' {
        Test-FmProcessAlive -Id $PID | Should -BeTrue
    }

    It 'reports a nonexistent process dead' {
        Test-FmProcessAlive -Id $script:DeadPid | Should -BeFalse
    }

    It 'reports a malformed id dead' -ForEach @(
        @{ Value = '' }, @{ Value = 'not-a-pid' }, @{ Value = '0' }, @{ Value = $null }
    ) {
        Test-FmProcessAlive -Id $Value | Should -BeFalse
    }

    It 'accepts a matching identity' {
        Test-FmProcessAlive -Id $PID -Identity (Get-FmProcessIdentity -Id $PID) | Should -BeTrue
    }

    It 'rejects a live id whose identity does not match - the recycled-id guard' {
        # The id is genuinely alive; the recorded identity belongs to a process
        # that is gone. Treating this as "held" would wedge the home forever.
        Test-FmProcessAlive -Id $PID -Identity 'proc-starttime=1 name=ghost' | Should -BeFalse
    }

    It 'reports alive when the current identity cannot be read - fail safe' {
        InModuleScope Firstmate {
            Mock Get-FmProcessIdentity { $null }
            # Unknown identity proves nothing, so the process must NOT be
            # declared dead: a wrong "dead" costs a live holder its lock.
            Test-FmProcessAlive -Id $PID -Identity 'anything' | Should -BeTrue
        }
    }

    It 'ignores an empty identity instead of treating it as a mismatch' {
        Test-FmProcessAlive -Id $PID -Identity '' | Should -BeTrue
    }
}

Describe 'Get-FmParentProcessId' {
    It 'finds a parent for this process' {
        Get-FmParentProcessId -Id $PID | Should -BeGreaterThan 1
    }

    It 'returns $null for a nonexistent process' {
        Get-FmParentProcessId -Id $script:DeadPid | Should -BeNullOrEmpty
    }
}

Describe 'Get-FmProcessAncestry' {
    It 'starts at the requested process' {
        (Get-FmProcessAncestry -Id $PID)[0] | Should -Be $PID
    }

    It 'never repeats a process id' {
        $ancestry = Get-FmProcessAncestry -Id $PID
        ($ancestry | Select-Object -Unique).Count | Should -Be $ancestry.Count
    }

    It 'honours the depth bound' {
        (Get-FmProcessAncestry -Id $PID -MaxDepth 2).Count | Should -BeLessOrEqual 2
    }

    It 'returns nothing for a nonexistent process' {
        (Get-FmProcessAncestry -Id $script:DeadPid).Count | Should -Be 0
    }
}

Describe 'Harness name matching' {
    It 'matches a whole path component: <Path> -> <Expected>' -ForEach @(
        @{ Path = '/home/u/.local/share/claude/versions/2.1.220'; Expected = 'claude' }
        @{ Path = 'C:\Users\u\AppData\Local\claude\versions\2.1.220.exe'; Expected = 'claude' }
        @{ Path = '/usr/local/bin/codex'; Expected = 'codex' }
        @{ Path = 'C:\tools\opencode.exe'; Expected = 'opencode' }
        @{ Path = '/opt/pi-signed/bin/pi-signed'; Expected = 'pi-signed' }
        @{ Path = '/usr/bin/pi'; Expected = 'pi' }
    ) {
        InModuleScope Firstmate -Parameters @{ Path = $Path; Expected = $Expected } {
            Get-FmPathHarnessName -Path $Path | Should -Be $Expected
        }
    }

    It 'does not match a substring: <Path>' -ForEach @(
        # This is the whole reason the match is per-component. A firstmate script
        # with a harness name in its FILENAME is not a harness process.
        @{ Path = '/home/u/firstmate/bin/fm-claude-stop-autoarm.ps1' }
        @{ Path = 'C:\firstmate\bin\fm-kimi-turnend-hook.ps1' }
        @{ Path = '/usr/bin/pwsh' }
        @{ Path = '/home/u/pizza/bin/tool' }
        @{ Path = '' }
        @{ Path = $null }
    ) {
        InModuleScope Firstmate -Parameters @{ Path = $Path } {
            Get-FmPathHarnessName -Path $Path | Should -BeNullOrEmpty
        }
    }

    It 'does not call this pwsh process a harness' {
        Test-FmHarnessProcess -Id $PID | Should -BeFalse
    }

    It 'reports a nonexistent process as not a harness' {
        Test-FmHarnessProcess -Id $script:DeadPid | Should -BeFalse
    }
}

Describe 'Get-FmHarnessAncestry' {
    # A synthetic tree: 10 (shell) -> 20 (claude) -> 30 (claude) -> 40 (bash) -> 50 (claude).
    # Pid 50 is an UNRELATED session further up the real process tree - for
    # example the live session that launched this test - and must never be
    # reported as part of this session's ancestry.

    It 'reports the contiguous Claude run and stops at the first non-harness ancestor' {
        InModuleScope Firstmate {
            Mock Get-FmProcessAncestry { @(10, 20, 30, 40, 50) }
            Mock Get-FmHarnessName {
                switch ($Id) { 20 { 'claude' } 30 { 'claude' } 50 { 'claude' } default { $null } }
            }
            # Assigned first, not piped: the function returns the array as one
            # object (deliberately, so a one-element result stays an array), and
            # piping it straight in would hand Should a single collection.
            $ancestry = Get-FmHarnessAncestry -Id 10
            $ancestry | Should -Be @(20, 30)
        }
    }

    It 'reports the outermost pid of that run as the session' {
        InModuleScope Firstmate {
            Mock Get-FmProcessAncestry { @(10, 20, 30, 40, 50) }
            Mock Get-FmHarnessName {
                switch ($Id) { 20 { 'claude' } 30 { 'claude' } 50 { 'claude' } default { $null } }
            }
            # The innermost Claude worker is reaped when its hook returns; a lock
            # naming it would look stale while the session is still running.
            Get-FmHarnessAncestryPid -Id 10 | Should -Be 30
        }
    }

    It 'stops at the innermost match for a non-Claude harness' {
        InModuleScope Firstmate {
            Mock Get-FmProcessAncestry { @(10, 20, 30) }
            Mock Get-FmHarnessName {
                switch ($Id) { 20 { 'pi' } 30 { 'pi-signed' } default { $null } }
            }
            # Pi's signed wrapper parents the inner engine pid that owns the
            # lock; the wrapper above it is not that owner.
            $ancestry = Get-FmHarnessAncestry -Id 10
            $ancestry | Should -Be @(20)
            Get-FmHarnessAncestryPid -Id 10 | Should -Be 20
        }
    }

    It 'returns nothing when no ancestor is a harness' {
        InModuleScope Firstmate {
            Mock Get-FmProcessAncestry { @(10, 40) }
            Mock Get-FmHarnessName { $null }
            (Get-FmHarnessAncestry -Id 10).Count | Should -Be 0
            Get-FmHarnessAncestryPid -Id 10 | Should -BeNullOrEmpty
        }
    }
}
