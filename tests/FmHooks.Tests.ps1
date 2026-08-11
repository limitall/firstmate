#requires -Version 7.0
# Pester tests for the Claude Code hook surface.
#
# WINDOWS-UNVERIFIED, and this test file is exactly where that line is drawn.
# What Claude Code on Windows DOES with a decision - whether it runs a
# PowerShell-native hook at all, delivers the payload on stdin, honours exit 2 as
# a block, and fires an asyncRewake Stop hook in the background - cannot be
# proven from Linux and is documented as unverified in
# docs/claude-hooks-windows.md.
#
# What these tests DO prove is everything on this side of that boundary: payload
# parsing, primary scoping, the supervision predicate, the epoch and budget file
# contracts, and which ExitCode/Stdout/Stderr each state of the machine produces.
# The hook functions return a decision object precisely so that is testable.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function Reset-TestEnvironment {
        foreach ($name in @(
                'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_GUARD_GRACE',
                'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS', 'FM_CLAUDE_AUTOARM_EPOCH_FRESH',
                'FM_CLAUDE_TURNEND_BLOCK_BUDGET', 'FM_CLAUDE_AUTOARM_ATTEMPTS',
                'FM_TASKS_AXI_COMPATIBLE')) {
            Set-Item -Path "env:$name" -Value $null
        }
    }

    # A home that passes the primary-scope predicate without needing a git
    # checkout: the secondmate marker force-includes a home, which is exactly the
    # branch a secondmate's own primary session takes.
    function New-TestPrimaryHome {
        param([switch]$InFlight)

        Reset-TestEnvironment
        $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'config', 'bin')) {
            New-Item -ItemType Directory -Path (Join-Path $home_ $sub) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $home_ 'AGENTS.md'), "fixture`n")
        [System.IO.File]::WriteAllText((Join-Path $home_ '.fm-secondmate-home'), "atlas`n")
        $env:FM_HOME = $home_
        $env:FM_ROOT_OVERRIDE = $home_
        # Keep every wait in these tests short: the state machine, not the clock,
        # is what is under test.
        $env:FM_CLAUDE_AUTOARM_SYNC_WAIT_MS = '100'
        if ($InFlight) {
            [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'task-a.meta'), "window=fm-task-a`n")
        }
        $home_
    }

    function New-StopPayload {
        param([bool]$StopHookActive = $false, [string]$SessionId = 'session-1')
        (@{ session_id = $SessionId; stop_hook_active = $StopHookActive; hook_event_name = 'Stop' } | ConvertTo-Json -Compress)
    }

}

Describe 'ConvertFrom-FmHookPayload and the loop-guard field' {
    It 'returns nothing for empty or malformed input, so a hook that cannot read its payload fails open' {
        ConvertFrom-FmHookPayload -Payload '' | Should -BeNullOrEmpty
        ConvertFrom-FmHookPayload -Payload 'not json' | Should -BeNullOrEmpty
        ConvertFrom-FmHookPayload -Payload '[1,2]' | Should -BeNullOrEmpty
    }

    It 'defaults the loop-guard field to false when absent' {
        Get-FmHookStopHookActive -Payload (ConvertFrom-FmHookPayload -Payload '{}') | Should -BeFalse
    }

    It 'gives the typed camel-case spelling precedence when both appear' {
        $payload = ConvertFrom-FmHookPayload -Payload '{"stopHookActive":true,"stop_hook_active":false}'
        Get-FmHookStopHookActive -Payload $payload | Should -BeTrue
    }

    It 'treats a non-boolean value as malformed rather than guessing' {
        $payload = ConvertFrom-FmHookPayload -Payload '{"stopHookActive":"yes"}'
        Get-FmHookStopHookActive -Payload $payload | Should -BeNullOrEmpty
    }
}

Describe 'Test-FmHookPrimaryScope' {
    It 'force-includes a genuinely marked secondmate home, which runs its own primary session' {
        $home_ = New-TestPrimaryHome
        Test-FmHookPrimaryScope -Root $home_ -State (Join-Path $home_ 'state') | Should -BeTrue
    }

    It 'rejects a marker whose first line is not a plain identifier' {
        $home_ = New-TestPrimaryHome
        [System.IO.File]::WriteAllText((Join-Path $home_ '.fm-secondmate-home'), "not a/valid id`n")
        # With no valid marker it falls through to the git-dir check, and this
        # fixture is not a checkout at all.
        Test-FmHookPrimaryScope -Root $home_ -State (Join-Path $home_ 'state') | Should -BeFalse
    }

    It 'rejects a home missing AGENTS.md, bin/, or its state dir' {
        $home_ = New-TestPrimaryHome
        Remove-Item -LiteralPath (Join-Path $home_ 'AGENTS.md') -Force
        Test-FmHookPrimaryScope -Root $home_ -State (Join-Path $home_ 'state') | Should -BeFalse

        $home2 = New-TestPrimaryHome
        Remove-Item -LiteralPath (Join-Path $home2 'bin') -Recurse -Force
        Test-FmHookPrimaryScope -Root $home2 -State (Join-Path $home2 'state') | Should -BeFalse

        $home3 = New-TestPrimaryHome
        Test-FmHookPrimaryScope -Root $home3 -State (Join-Path $home3 'no-such-state') | Should -BeFalse
    }

    It 'keeps a crewmate linked worktree inert' {
        # A linked worktree has git-dir != git-common-dir and never carries the
        # marker, which is the whole exemption.
        $worktree = Join-Path $TestDrive 'crew-worktree'
        New-Item -ItemType Directory -Path (Join-Path $worktree 'bin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $worktree 'state') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $worktree 'AGENTS.md'), "fixture`n")
        Test-FmHookPrimaryScope -Root $worktree -State (Join-Path $worktree 'state') | Should -BeFalse
    }
}

Describe 'Get-FmHookSupervisionStatus' {
    It 'needs supervision while work is in flight' {
        $home_ = New-TestPrimaryHome -InFlight
        $status = Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state')
        $status.InFlight | Should -Be 1
        $status.Needed | Should -BeTrue
        $status.BeaconDesc | Should -Be 'never'
    }

    It 'needs supervision for a relay poll even with no task at all' {
        $home_ = New-TestPrimaryHome
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'x-watch.check.sh'), "#!/bin/sh`n")
        (Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state')).Needed | Should -BeTrue
    }

    It 'needs supervision for a registered process-event source, which has no task metadata' {
        $home_ = New-TestPrimaryHome
        $dir = Join-Path $home_ 'state' 'procevent'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'build.source'), "id=build`n")
        $status = Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state')
        $status.Sources | Should -Be 1
        $status.Needed | Should -BeTrue
    }

    It 'needs nothing in an idle home' {
        $home_ = New-TestPrimaryHome
        (Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state')).Needed | Should -BeFalse
    }

    It 'reports a fresh beacon as fresh and a stale one as not' {
        $home_ = New-TestPrimaryHome -InFlight
        $beat = Join-Path $home_ 'state' '.last-watcher-beat'
        [System.IO.File]::WriteAllText($beat, '')
        (Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state') -Grace 300).WatcherFresh | Should -BeTrue
        (Get-Item -LiteralPath $beat -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-600)
        (Get-FmHookSupervisionStatus -State (Join-Path $home_ 'state') -Grace 300).WatcherFresh | Should -BeFalse
    }
}

Describe 'Get-FmHookSessionStartRoute' {
    It 'runs the full digest for a fresh startup' {
        Get-FmHookSessionStartRoute -Source 'startup' -StartupCompleted $false | Should -Be 'full'
        Get-FmHookSessionStartRoute -Source 'new' -StartupCompleted $true | Should -Be 'full'
    }

    It 'delegates to the nudge when prior context is restored' {
        foreach ($source in @('resume', 'reload', 'fork')) {
            Get-FmHookSessionStartRoute -Source $source -StartupCompleted $true | Should -Be 'nudge'
        }
    }

    It 're-emits after a clear or compact only when this lock owner finished a full startup' {
        Get-FmHookSessionStartRoute -Source 'clear' -StartupCompleted $true | Should -Be 'reemit'
        Get-FmHookSessionStartRoute -Source 'compact' -StartupCompleted $true | Should -Be 'reemit'
        # A startup killed mid-sweep is finished first, never re-emitted.
        Get-FmHookSessionStartRoute -Source 'compact' -StartupCompleted $false | Should -Be 'full'
    }

    It 'treats an unreadable source as startup, because taking the helm redundantly is the cheap failure' {
        Get-FmHookSessionStartRoute -Source '' -StartupCompleted $false | Should -Be 'full'
        Get-FmHookSessionStartRoute -Source 'something-new' -StartupCompleted $true | Should -Be 'full'
    }
}

Describe 'Test-FmHookStartupCompleted' {
    It 'is true only when the completion record names the current lock owner' {
        $home_ = New-TestPrimaryHome
        $state = Join-Path $home_ 'state'
        Test-FmHookStartupCompleted -State $state | Should -BeFalse

        [System.IO.File]::WriteAllText((Join-Path $state '.lock'), "4242`n")
        [System.IO.File]::WriteAllText((Join-Path $state '.session-start-complete'), "9999`n")
        Test-FmHookStartupCompleted -State $state | Should -BeFalse

        [System.IO.File]::WriteAllText((Join-Path $state '.session-start-complete'), "4242`n")
        Test-FmHookStartupCompleted -State $state | Should -BeTrue
    }
}

Describe 'Invoke-FmClaudeSessionStartHook' {
    It 'stays inert outside a primary checkout' {
        Reset-TestEnvironment
        $worktree = Join-Path $TestDrive 'not-a-primary'
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        $env:FM_HOME = $worktree
        $env:FM_ROOT_OVERRIDE = $worktree
        $decision = Invoke-FmClaudeSessionStartHook -Payload '{"source":"startup"}'
        $decision.ExitCode | Should -Be 0
        $decision.Stdout.Count | Should -Be 0
    }

    It 'runs the digest at startup and exits 0, because an exit 2 would block session initialization' {
        New-TestPrimaryHome | Out-Null
        $env:FM_TASKS_AXI_COMPATIBLE = '0'
        $decision = Invoke-FmClaudeSessionStartHook -Payload '{"source":"startup"}'
        $decision.ExitCode | Should -Be 0
        $decision.Stdout | Should -Contain 'READ-ONCE CONTRACT'
    }

    It 'reads the session-open source out of the payload' {
        New-TestPrimaryHome | Out-Null
        function Invoke-FmSessionStartNudge { 'FIRSTMATE_OP: take the helm' }
        try {
            $decision = Invoke-FmClaudeSessionStartHook -Payload '{"source":"resume"}'
            $decision.Stdout | Should -Contain 'FIRSTMATE_OP: take the helm'
        } finally {
            Remove-Item -Path 'function:Invoke-FmSessionStartNudge' -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-FmClaudePreToolUseHook' {
    It 'allows on a malformed payload' {
        New-TestPrimaryHome | Out-Null
        (Invoke-FmClaudePreToolUseHook -Payload 'not json').ExitCode | Should -Be 0
    }

    It 'allows when the policy owner is not loaded, because only the owner may decide deny' {
        New-TestPrimaryHome | Out-Null
        $payload = '{"tool_input":{"command":"bin/fm-watch-arm.sh"}}'
        (Invoke-FmClaudePreToolUseHook -Payload $payload -Check arm).ExitCode | Should -Be 0
    }

    It 'reads the command from either the Claude or the Grok payload shape' {
        New-TestPrimaryHome | Out-Null
        Get-FmHookToolCommand -Payload (ConvertFrom-FmHookPayload -Payload '{"tool_input":{"command":"a"}}') | Should -Be 'a'
        Get-FmHookToolCommand -Payload (ConvertFrom-FmHookPayload -Payload '{"toolInput":{"command":"b"}}') | Should -Be 'b'
        Get-FmHookToolCommand -Payload (ConvertFrom-FmHookPayload -Payload '{}') | Should -Be ''
    }

    It 'denies with exit 2, a Claude-shaped object on stderr, and an EMPTY stdout' {
        New-TestPrimaryHome | Out-Null
        function Test-FmArmCommandPolicy {
            param($Command)
            [pscustomobject]@{ Deny = $true; Code = 'ARM_BACKGROUNDED'; Reason = 'the watcher arm must be a standalone verified harness call' }
        }
        try {
            $decision = Invoke-FmClaudePreToolUseHook -Payload '{"tool_input":{"command":"bin/fm-watch-arm.sh &"}}' -Check arm
            $decision.ExitCode | Should -Be 2
            $decision.Stdout.Count | Should -Be 0
            $body = $decision.Stderr[0] | ConvertFrom-Json
            $body.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
            $body.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $body.systemMessage | Should -Be '[ARM_BACKGROUNDED] the watcher arm must be a standalone verified harness call'
        } finally {
            Remove-Item -Path 'function:Test-FmArmCommandPolicy' -ErrorAction SilentlyContinue
        }
    }

    It 'fails open on an invalid policy verdict' {
        New-TestPrimaryHome | Out-Null
        function Test-FmArmCommandPolicy { param($Command) [pscustomobject]@{ Deny = $true; Code = ''; Reason = '' } }
        try {
            (Invoke-FmClaudePreToolUseHook -Payload '{"tool_input":{"command":"x"}}' -Check arm).ExitCode | Should -Be 0
        } finally {
            Remove-Item -Path 'function:Test-FmArmCommandPolicy' -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-FmClaudeTurnEndGuard' {
    It 'allows on empty or malformed input' {
        New-TestPrimaryHome -InFlight | Out-Null
        (Invoke-FmClaudeTurnEndGuard -Payload '' -ClaudeMode).ExitCode | Should -Be 0
        (Invoke-FmClaudeTurnEndGuard -Payload 'not json' -ClaudeMode).ExitCode | Should -Be 0
        (Invoke-FmClaudeTurnEndGuard -Payload '{"stopHookActive":"yes"}' -ClaudeMode).ExitCode | Should -Be 0
    }

    It 'honours the one-shot loop guard OUTSIDE claude mode' {
        New-TestPrimaryHome -InFlight | Out-Null
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -StopHookActive $true)).ExitCode | Should -Be 0
    }

    It 'IGNORES the loop guard in claude mode, because Claude marks every post-continuation stop active' {
        New-TestPrimaryHome -InFlight | Out-Null
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -StopHookActive $true) -ClaudeMode).ExitCode | Should -Be 2
    }

    It 'allows when the home needs no supervision at all' {
        New-TestPrimaryHome | Out-Null
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
    }

    It 'FAILS OPEN when the watcher predicate owner is not loaded, rather than wedging every turn end' {
        New-TestPrimaryHome -InFlight | Out-Null
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
    }

    It 'allows immediately when a live identity-matched watcher has a fresh beacon' {
        New-TestPrimaryHome -InFlight | Out-Null
        function Test-FmWatcherHealthy { param($State, $Grace) $true }
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
    }

    It 'blocks with the repair banner when no watcher and no auto-arm claim exist' {
        New-TestPrimaryHome -InFlight | Out-Null
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        $decision = Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode
        $decision.ExitCode | Should -Be 2
        $decision.Stderr | Should -Contain '●  TURN WOULD END BLIND - SUPERVISION IS OFF'
        $decision.Stderr | Should -Contain '●  1 task(s) in flight, but no live watcher holds this home lock (last beat: never).'
        $decision.Stderr | Should -Contain '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.'
    }

    It 'names the relay poll rather than a task when that is the actual supervision need' {
        $home_ = New-TestPrimaryHome
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' 'x-watch.check.sh'), "#!/bin/sh`n")
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        $decision = Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode
        $decision.Stderr | Should -Contain '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: never).'
    }

    It 'allows without consuming a continuation while the auto-arm owner lock is alive' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        $lock = Join-Path $home_ 'state' '.claude-autoarm.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), "$PID`n")
        [System.IO.File]::WriteAllText((Join-Path $lock 'role'), "autoarm`n")
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'state' '.turnend-claude-blocks') | Should -BeFalse
    }

    It 'allows on a fresh rewake epoch this auto-arm already owns' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' '.claude-autoarm-epoch'),
            "epoch=7 owner_pid=1234 outcome=rewake updated_at=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`n")
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
    }

    It 'blocks again on a STALE rewake epoch' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        $epoch = Join-Path $home_ 'state' '.claude-autoarm-epoch'
        [System.IO.File]::WriteAllText($epoch, "epoch=7 owner_pid=1234 outcome=rewake updated_at=1`n")
        (Get-Item -LiteralPath $epoch -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-600)
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 2
    }

    It 'accounts one block per event epoch and keeps the budget record in the shared byte layout' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -SessionId 's1') -ClaudeMode | Out-Null
        [System.IO.File]::ReadAllText((Join-Path $home_ 'state' '.turnend-claude-blocks')) |
            Should -Be "session=s1`ncount=1`nepoch=`n"
        Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -SessionId 's1') -ClaudeMode | Out-Null
        (Get-FmHookBudgetRecord -State (Join-Path $home_ 'state')).Count | Should -Be 2
    }

    It 'takes the one loud attended fail-open only for a verified exhausted failure episode' {
        $home_ = New-TestPrimaryHome -InFlight
        $state = Join-Path $home_ 'state'
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        # A verified failure episode: the auto-arm recorded an exhausted failure
        # and its one notice is already consumed.
        [System.IO.File]::WriteAllText((Join-Path $state '.claude-autoarm-failure-notified'), '')
        [System.IO.File]::WriteAllText((Join-Path $state '.claude-autoarm-epoch'), "epoch=9 owner_pid=1 outcome=failed updated_at=1`n")
        (Get-Item -LiteralPath (Join-Path $state '.claude-autoarm-epoch') -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-600)
        # The budget is already at its bound, so this stop is the one past it.
        [System.IO.File]::WriteAllText((Join-Path $state '.turnend-claude-blocks'), "session=s1`ncount=3`nepoch=1`n")

        $decision = Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -SessionId 's1') -ClaudeMode
        $decision.ExitCode | Should -Be 0
        ($decision.Stdout[0] | ConvertFrom-Json).systemMessage |
            Should -BeLike 'FIRSTMATE SUPERVISION IS GENUINELY DOWN: 1 task(s) in flight,*'
        Test-Path -LiteralPath (Join-Path $state '.claude-autoarm-failure-alarmed') | Should -BeTrue

        # The alarm cannot repeat during that failure episode: a later unhealthy
        # stop blocks again instead.
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -SessionId 's1') -ClaudeMode).ExitCode | Should -Be 2
    }

    It 'refuses the attended fail-open while away mode is active' {
        $home_ = New-TestPrimaryHome -InFlight
        $state = Join-Path $home_ 'state'
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        [System.IO.File]::WriteAllText((Join-Path $state '.afk'), '')
        [System.IO.File]::WriteAllText((Join-Path $state '.claude-autoarm-failure-notified'), '')
        [System.IO.File]::WriteAllText((Join-Path $state '.claude-autoarm-epoch'), "epoch=9 owner_pid=1 outcome=failed updated_at=1`n")
        (Get-Item -LiteralPath (Join-Path $state '.claude-autoarm-epoch') -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-600)
        [System.IO.File]::WriteAllText((Join-Path $state '.turnend-claude-blocks'), "session=s1`ncount=3`nepoch=1`n")
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload -SessionId 's1') -ClaudeMode).ExitCode | Should -Be 2
    }

    It 'clears the whole failure episode on positive watcher recovery' {
        $home_ = New-TestPrimaryHome -InFlight
        $state = Join-Path $home_ 'state'
        foreach ($name in @('.turnend-claude-blocks', '.claude-autoarm-failure-notified', '.claude-autoarm-failure-alarmed')) {
            [System.IO.File]::WriteAllText((Join-Path $state $name), '')
        }
        function Test-FmWatcherHealthy { param($State, $Grace) $true }
        (Invoke-FmClaudeTurnEndGuard -Payload (New-StopPayload) -ClaudeMode).ExitCode | Should -Be 0
        foreach ($name in @('.turnend-claude-blocks', '.claude-autoarm-failure-notified', '.claude-autoarm-failure-alarmed')) {
            Test-Path -LiteralPath (Join-Path $state $name) | Should -BeFalse
        }
    }
}

Describe 'Invoke-FmClaudeStopAutoArm' {
    It 'stays inert outside a primary checkout' {
        Reset-TestEnvironment
        $worktree = Join-Path $TestDrive 'autoarm-not-primary'
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        $env:FM_HOME = $worktree
        $env:FM_ROOT_OVERRIDE = $worktree
        (Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)).ExitCode | Should -Be 0
    }

    It 'never rewakes while away mode is active, because the daemon owns the watcher' {
        $home_ = New-TestPrimaryHome -InFlight
        [System.IO.File]::WriteAllText((Join-Path $home_ 'state' '.afk'), '')
        function Invoke-FmWatchArm { 'signal: something happened' }
        $decision = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $decision.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'state' '.claude-autoarm-epoch') | Should -BeFalse
    }

    It 'stays inert in an idle home' {
        $home_ = New-TestPrimaryHome
        function Invoke-FmWatchArm { 'signal: something happened' }
        (Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'state' '.claude-autoarm-epoch') | Should -BeFalse
    }

    It 'stays inert when the arm owner is not loaded' {
        New-TestPrimaryHome -InFlight | Out-Null
        (Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)).ExitCode | Should -Be 0
    }

    It 'translates an actionable arm close into an exit-2 rewake and records the epoch' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        function Invoke-FmWatchArm { 'watcher: started'; 'signal: task-a wrote a status line' }
        $decision = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $decision.ExitCode | Should -Be 2
        $decision.Stderr[0] | Should -Be 'firstmate watcher wake - one supervision event needs a handling turn now.'
        $decision.Stderr | Should -Contain 'signal: task-a wrote a status line'

        # The epoch ledger is a shared file contract with the bash implementation.
        $record = [System.IO.File]::ReadAllText((Join-Path $home_ 'state' '.claude-autoarm-epoch'))
        $record | Should -Match "^epoch=2 owner_pid=$PID outcome=rewake updated_at=\d+\n$"
    }

    It 'closes quietly when a healthy watcher already owns the home' {
        $home_ = New-TestPrimaryHome -InFlight
        function Test-FmWatcherHealthy { param($State, $Grace) $true }
        function Invoke-FmWatchArm { 'watcher: attached' }
        $decision = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $decision.ExitCode | Should -Be 0
        (Get-FmHookEpochRecord -State (Join-Path $home_ 'state')).Outcome | Should -Be 'clean'
    }

    It 'emits exactly one failure notice per episode, and still exits 2 afterwards' {
        $home_ = New-TestPrimaryHome -InFlight
        $state = Join-Path $home_ 'state'
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        function Invoke-FmWatchArm { 'watcher: could not start' }

        $first = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $first.ExitCode | Should -Be 2
        $first.Stderr[0] | Should -BeLike 'firstmate watcher auto-arm FAILED - *'
        $first.Stderr[-1] | Should -Be 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.'
        Test-Path -LiteralPath (Join-Path $state '.claude-autoarm-failure-notified') | Should -BeTrue
        (Get-FmHookEpochRecord -State $state).Outcome | Should -Be 'failed'

        $second = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $second.ExitCode | Should -Be 2
        $second.Stderr.Count | Should -Be 0
        (Get-FmHookEpochRecord -State $state).Outcome | Should -Be 'failed-suppressed'
    }

    It 'stops creating exit-2 continuations once the attended alarm has been consumed' {
        $home_ = New-TestPrimaryHome -InFlight
        $state = Join-Path $home_ 'state'
        function Test-FmWatcherHealthy { param($State, $Grace) $false }
        [System.IO.File]::WriteAllText((Join-Path $state '.claude-autoarm-failure-alarmed'), '')
        function Invoke-FmWatchArm { 'watcher: could not start' }
        $decision = Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)
        $decision.ExitCode | Should -Be 0
        (Get-FmHookEpochRecord -State $state).Outcome | Should -Be 'failed-suppressed'
    }

    It 'admits exactly one owner, so one event epoch maps to one recovery turn' {
        $home_ = New-TestPrimaryHome -InFlight
        $lock = Join-Path $home_ 'state' '.claude-autoarm.lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), "1`n")
        function Invoke-FmWatchArm { 'signal: something' }
        (Invoke-FmClaudeStopAutoArm -Payload (New-StopPayload)).ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $home_ 'state' '.claude-autoarm-epoch') | Should -BeFalse
    }
}

Describe 'Get-FmClaudeHookSettings' {
    It 'registers all three events with PowerShell-native hooks' {
        $settings = Get-FmClaudeHookSettings -AsObject
        $settings.hooks.Keys | Should -Contain 'SessionStart'
        $settings.hooks.Keys | Should -Contain 'PreToolUse'
        $settings.hooks.Keys | Should -Contain 'Stop'
        $settings.hooks.SessionStart[0].hooks[0].shell | Should -Be 'powershell'
    }

    It 'registers both Bash PreToolUse guards and the all-tools subagent guard' {
        $settings = Get-FmClaudeHookSettings -AsObject
        $settings.hooks.PreToolUse[0].matcher | Should -Be 'Bash'
        $settings.hooks.PreToolUse[0].hooks.Count | Should -Be 2
        $settings.hooks.PreToolUse[1].matcher | Should -Be '.*'
    }

    It 'gives the Stop auto-arm asyncRewake and its multi-hour timeout, and the guard neither' {
        $settings = Get-FmClaudeHookSettings -AsObject
        $guard = $settings.hooks.Stop[0].hooks[0]
        $autoarm = $settings.hooks.Stop[0].hooks[1]
        $guard.command | Should -BeLike '*-Event Stop -Check turnend-guard*'
        $guard.Keys | Should -Not -Contain 'asyncRewake'
        $autoarm.command | Should -BeLike '*-Event Stop -Check autoarm*'
        $autoarm.asyncRewake | Should -BeTrue
        $autoarm.timeout | Should -Be 28800
    }

    It 'renders as JSON' {
        (Get-FmClaudeHookSettings) | ConvertFrom-Json | Should -Not -BeNullOrEmpty
    }
}

Describe 'bin/fm-claude-hook.ps1 end to end' {
    # These drive the REAL entry point in a REAL child process with a REAL piped
    # payload, which is the only way to catch a fault in the transport rather
    # than in the state machine. One already escaped the unit tests: an unbound
    # [string] parameter arrives as the empty string, not $null, so the hook
    # never read stdin and every event failed open.
    BeforeAll {
        # A throwaway checkout carrying this module plus a stand-in watcher-area
        # owner, so the guard can evaluate its predicate for real.
        $script:E2ERoot = Join-Path $TestDrive 'e2e-checkout'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'module') -Destination (Join-Path $script:E2ERoot 'module') -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'bin') -Destination (Join-Path $script:E2ERoot 'bin') -Recurse -Force
        foreach ($sub in @('state', 'data', 'config')) {
            New-Item -ItemType Directory -Path (Join-Path $script:E2ERoot $sub) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $script:E2ERoot 'AGENTS.md'), "fixture`n")
        [System.IO.File]::WriteAllText((Join-Path $script:E2ERoot '.fm-secondmate-home'), "atlas`n")
        [System.IO.File]::WriteAllText((Join-Path $script:E2ERoot 'state' 'task-a.meta'), "window=fm-task-a`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $script:E2ERoot 'module' 'Firstmate' 'Private' 'ZZTestWatcherStub.ps1'),
            "function Test-FmWatcherHealthy { param(`$State, `$Grace) `$false }`n")

        function Invoke-HookEntryPoint {
            param([string]$Payload, [string[]]$HookArguments)

            $entry = Join-Path $script:E2ERoot 'bin' 'fm-claude-hook.ps1'
            $stdout = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            $stderr = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            $stdin = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            [System.IO.File]::WriteAllText($stdin, $Payload)

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = (Get-Process -Id $PID).Path
            foreach ($a in (@('-NoProfile', '-NonInteractive', '-File', $entry) + $HookArguments)) {
                $psi.ArgumentList.Add($a)
            }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['FM_HOME'] = $script:E2ERoot
            $psi.EnvironmentVariables['FM_ROOT_OVERRIDE'] = $script:E2ERoot
            $psi.EnvironmentVariables['FM_CLAUDE_AUTOARM_SYNC_WAIT_MS'] = '100'
            $psi.EnvironmentVariables['FM_TASKS_AXI_COMPATIBLE'] = '0'

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Write($Payload)
            $proc.StandardInput.Close()
            $out = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $code = $proc.ExitCode
            $proc.Dispose()
            Remove-Item -LiteralPath $stdout, $stderr, $stdin -Force -ErrorAction SilentlyContinue
            [pscustomobject]@{ ExitCode = $code; Stdout = $out; Stderr = $err }
        }
    }

    It 'reads the payload from stdin and blocks the Stop with exit 2 plus the banner on stderr' {
        $result = Invoke-HookEntryPoint -Payload '{"session_id":"s1","stop_hook_active":true}' `
            -HookArguments @('-Event', 'Stop', '-Check', 'turnend-guard')
        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -BeLike '*TURN WOULD END BLIND - SUPERVISION IS OFF*'
        $result.Stderr | Should -BeLike '*1 task(s) in flight*'
        $result.Stdout | Should -Be ''
    }

    It 'exits 0 and prints the digest for a SessionStart, because exit 2 would block session initialization' {
        $result = Invoke-HookEntryPoint -Payload '{"source":"startup"}' -HookArguments @('-Event', 'SessionStart')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeLike '*READ-ONCE CONTRACT*'
    }

    It 'allows a PreToolUse call when no policy owner is loaded' {
        $result = Invoke-HookEntryPoint -Payload '{"tool_input":{"command":"bin/fm-watch-arm.ps1"}}' `
            -HookArguments @('-Event', 'PreToolUse', '-Check', 'arm')
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Be ''
    }
}
