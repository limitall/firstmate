#requires -Version 7.0
# Pester 5+/6 tests for the delivery surface: the mode gate, the guarded local
# landing path, and scout -> ship promotion.
#
# The merge tests run against REAL git repositories created in TestDrive,
# because every guard they cover is a property of a real repository: a mocked
# `merge-base --is-ancestor` would only prove the mock agrees with itself, and
# the whole point of these guards is that they hold against git's actual answer.
#
# Refusals are tested as thoroughly as successes. A refusal that is not tested
# is a refusal that will not happen.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestRepo {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $Path)
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.name', 'Test')
        Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'seed'
        $null = Invoke-FmGit -Directory $Path -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $Path -Arguments @('commit', '-q', '-m', 'seed')
        $Path
    }

    function New-TestCommit {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name
        )
        Set-Content -LiteralPath (Join-Path $Path $Name) -Value $Name
        $null = Invoke-FmGit -Directory $Path -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $Path -Arguments @('commit', '-q', '-m', $Name)
    }

    function New-TestTaskMeta {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$StateDir,
            [Parameter(Mandatory)][string]$TaskId,
            [Parameter(Mandatory)][string[]]$Lines
        )
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        $path = Join-Path $StateDir "$TaskId.meta"
        [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"))
        $path
    }

    # One fixture home + project per test, so no test can see another's state.
    function New-TestFixture {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Branch = 'fm/task1')
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $state = Join-Path $root 'state'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $project = New-TestRepo -Path (Join-Path $root 'projects/thing')
        $null = Invoke-FmGit -Directory $project -Arguments @('checkout', '-q', '-b', $Branch)
        New-TestCommit -Path $project -Name 'work.txt'
        $null = Invoke-FmGit -Directory $project -Arguments @('checkout', '-q', 'main')
        [pscustomobject]@{ Root = $root; State = $state; Project = $project; Branch = $Branch }
    }
}

Describe 'Get-FmDeliveryModeSupport' {
    It 'ships direct-PR and local-only as first-class' {
        foreach ($mode in @('direct-PR', 'local-only')) {
            $verdict = Get-FmDeliveryModeSupport -Mode $mode
            $verdict.Known | Should -BeTrue
            $verdict.Supported | Should -BeTrue
            $verdict.Reason | Should -Be ''
        }
    }

    It 'refuses no-mistakes as a real mode this port cannot run, not as an unknown one' {
        $verdict = Get-FmDeliveryModeSupport -Mode 'no-mistakes'
        $verdict.Known | Should -BeTrue
        $verdict.Supported | Should -BeFalse
        $verdict.Reason | Should -BeLike '*no established Windows support*'
        $verdict.Reason | Should -BeLike '*direct-PR or local-only*'
    }

    It 'reports an unknown mode differently from an unsupported one' {
        $verdict = Get-FmDeliveryModeSupport -Mode 'turbo'
        $verdict.Known | Should -BeFalse
        $verdict.Reason | Should -BeLike '*is not a task delivery mode*'
    }

    It 'accepts the conditional policy as a REGISTRY mode but still refuses to register it' {
        (Get-FmDeliveryModeSupport -Mode 'no-mistakes-prod-only').Known | Should -BeFalse
        $verdict = Get-FmDeliveryModeSupport -Mode 'no-mistakes-prod-only' -Registry
        $verdict.Known | Should -BeTrue
        $verdict.Supported | Should -BeFalse
        $verdict.Reason | Should -BeLike '*product-facing leg runs the no-mistakes pipeline*'
    }

    It 'throws from the Assert- form so the refusal cannot be downgraded to a warning' {
        { Assert-FmDeliveryModeSupported -Mode 'no-mistakes' } | Should -Throw '*not supported by this Windows port*'
        Assert-FmDeliveryModeSupported -Mode 'local-only' | Should -BeTrue
    }
}

Describe 'New-FmDeliveryLock' {
    It 'grants the lock once and refuses the second holder' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        (New-FmDeliveryLock -Path $lock).Acquired | Should -BeTrue
        $second = New-FmDeliveryLock -Path $lock
        $second.Acquired | Should -BeFalse
        $second.HeldByPid | Should -Be ([string]$PID)
    }

    It 'records the owner pid and its identity, so PID reuse cannot look like the same owner' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        $null = New-FmDeliveryLock -Path $lock
        (Get-Content -LiteralPath (Join-Path $lock 'pid') -Raw).Trim() | Should -Be ([string]$PID)
        (Get-Content -LiteralPath (Join-Path $lock 'pid-identity') -Raw).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'refuses to steal a lock whose owner is still alive' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        $null = New-FmDeliveryLock -Path $lock
        (New-FmDeliveryLock -Path $lock -StealStale).Acquired | Should -BeFalse
    }

    It 'recovers a lock left behind by a dead owner' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        New-Item -ItemType Directory -Path $lock | Out-Null
        # A pid that is not running, with an identity that cannot match.
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), "999999`n")
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid-identity'), "1999-01-01T00:00:00.0000000Z`n")
        (New-FmDeliveryLock -Path $lock -StealStale).Acquired | Should -BeTrue
    }

    It 'treats a pid-less lock as held while it is fresh' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        New-Item -ItemType Directory -Path $lock | Out-Null
        (New-FmDeliveryLock -Path $lock -StealStale).Acquired | Should -BeFalse
    }

    It 'releases only its own lock' {
        $lock = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        New-Item -ItemType Directory -Path $lock | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $lock 'pid'), "999999`n")
        Remove-FmDeliveryLock -Path $lock | Should -BeFalse
        Test-Path -LiteralPath $lock | Should -BeTrue

        $mine = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.lock')
        $null = New-FmDeliveryLock -Path $mine
        Remove-FmDeliveryLock -Path $mine | Should -BeTrue
        Test-Path -LiteralPath $mine | Should -BeFalse
    }
}

Describe 'Invoke-FmMergeLocal' {
    It 'fast-forwards the default branch to the task branch' {
        $fx = New-TestFixture
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'kind=ship', 'mode=local-only', 'yolo=off')
        $before = Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main')

        $result = Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State
        $result.Merged | Should -BeTrue
        $result.Message | Should -BeLike "merged fm/task1 into local main (* -> *) in $($fx.Project)"
        Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main') |
            Should -Be (Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'fm/task1'))
        Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main') | Should -Not -Be $before
    }

    It 'refuses a task that is not mode=local-only' {
        $fx = New-TestFixture
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'kind=ship', 'mode=direct-PR')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } |
            Should -Throw '*is mode=direct-PR, not local-only*'
    }

    It 'refuses a task with no meta at all' {
        $fx = New-TestFixture
        { Invoke-FmMergeLocal -TaskId 'ghost' -StateDir $fx.State } | Should -Throw '*no meta for task ghost*'
    }

    It 'refuses when the task branch does not exist' {
        $fx = New-TestFixture
        $null = Invoke-FmGit -Directory $fx.Project -Arguments @('branch', '-D', 'fm/task1')
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } |
            Should -Throw '*branch fm/task1 does not exist*'
    }

    It 'refuses when the project checkout is not on its default branch' {
        $fx = New-TestFixture
        $null = Invoke-FmGit -Directory $fx.Project -Arguments @('checkout', '-q', '-b', 'sidequest')
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } |
            Should -Throw "*is on 'sidequest', expected default branch 'main'*"
    }

    It 'refuses a dirty project working tree rather than merging over it' {
        $fx = New-TestFixture
        Set-Content -LiteralPath (Join-Path $fx.Project 'scratch.txt') -Value 'uncommitted'
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } |
            Should -Throw '*has a dirty working tree; refusing to merge into it*'
    }

    It 'refuses a diverged branch and names the rebase as the fix' {
        $fx = New-TestFixture
        # Advance main so the task branch is no longer a fast-forward.
        New-TestCommit -Path $fx.Project -Name 'mainline.txt'
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } |
            Should -Throw '*REFUSED: fm/task1 is not a fast-forward of main (it has diverged).*'
    }

    It 'leaves the project untouched when it refuses' {
        $fx = New-TestFixture
        New-TestCommit -Path $fx.Project -Name 'mainline.txt'
        $before = Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main')
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        { Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State } | Should -Throw
        Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main') | Should -Be $before
    }

    It 'changes nothing under -WhatIf' {
        $fx = New-TestFixture
        $null = New-TestTaskMeta -StateDir $fx.State -TaskId 'task1' -Lines @(
            'id=task1', "project=$($fx.Project)", 'mode=local-only')
        $before = Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main')
        Invoke-FmMergeLocal -TaskId 'task1' -StateDir $fx.State -WhatIf | Should -BeNullOrEmpty
        Get-FmGitOutput -Directory $fx.Project -Arguments @('rev-parse', 'main') | Should -Be $before
    }

    It 'refuses an invalid task id before touching anything' {
        $fx = New-TestFixture
        { Invoke-FmMergeLocal -TaskId '../escape' -StateDir $fx.State } | Should -Throw '*not a valid task id*'
    }
}

Describe 'Invoke-FmPromote' {
    BeforeEach {
        $script:state = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $script:state -Force | Out-Null
        $null = New-TestTaskMeta -StateDir $script:state -TaskId 'scout1' -Lines @(
            'id=scout1', 'project=/tmp/whatever', 'window=fm-scout1', 'kind=scout', 'harness=claude')
    }

    It 'flips kind to ship and records the decided contract, preserving every other field and its order' {
        $result = Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' `
            -StateDir $script:state -FirstmateHome '/fm/home'
        $result.Promoted | Should -BeTrue
        $result.Message | Should -Be 'promoted scout1 to ship mode=local-only yolo=off (teardown protection restored)'

        $lines = @(Get-FmSessionFileLines -Path (Join-Path $script:state 'scout1.meta'))
        $lines | Should -Be @('id=scout1', 'project=/tmp/whatever', 'window=fm-scout1', 'harness=claude',
            'kind=ship', 'mode=local-only', 'yolo=off')
    }

    It 'writes the record LF-only with no BOM' {
        $null = Invoke-FmPromote -TaskId 'scout1' -Mode 'direct-PR' -Yolo 'on' -StateDir $script:state
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:state 'scout1.meta'))
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        ($bytes -contains 13) | Should -BeFalse
    }

    It 'replaces an existing mode and yolo instead of appending a second one' {
        $null = New-TestTaskMeta -StateDir $script:state -TaskId 'scout2' -Lines @(
            'id=scout2', 'kind=scout', 'mode=stale', 'yolo=on')
        $null = Invoke-FmPromote -TaskId 'scout2' -Mode 'local-only' -Yolo 'off' -StateDir $script:state
        $lines = @(Get-FmSessionFileLines -Path (Join-Path $script:state 'scout2.meta'))
        @($lines | Where-Object { $_ -like 'mode=*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -like 'yolo=*' }).Count | Should -Be 1
        $lines | Should -Contain 'mode=local-only'
    }

    It 'emits ship instructions that require a clean default-branch base and leave scratch behind' {
        $result = Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' `
            -StateDir $script:state -FirstmateHome '/fm/home'
        $result.NextStep | Should -BeLike '*fm-send.ps1 fm-scout1*'
        $result.NextStep | Should -BeLike '*reset to a clean default-branch base*'
        $result.NextStep | Should -BeLike '*carry over only intended fix changes*'
        $result.NextStep | Should -BeLike '*create branch fm/scout1*'
        $result.NextStep | Should -BeLike "*`$env:FM_HOME = '/fm/home'*"
    }

    It 'refuses a task that is not a scout' {
        $null = New-TestTaskMeta -StateDir $script:state -TaskId 'shipped' -Lines @('id=shipped', 'kind=ship')
        { Invoke-FmPromote -TaskId 'shipped' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*is not a scout task (kind=scout not in meta)*'
    }

    It 'requires kind=scout as a whole line, not a prefix' {
        $null = New-TestTaskMeta -StateDir $script:state -TaskId 'sneaky' -Lines @('id=sneaky', 'kind=scoutish')
        { Invoke-FmPromote -TaskId 'sneaky' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*is not a scout task*'
    }

    It 'refuses the conditional registry policy by name' {
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'no-mistakes-prod-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*is a registry policy, not a task mode*'
    }

    It 'refuses a mode this port cannot deliver rather than recording it' {
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'no-mistakes' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*not supported by this Windows port*'
        @(Get-FmSessionFileLines -Path (Join-Path $script:state 'scout1.meta')) | Should -Contain 'kind=scout'
    }

    It 'refuses an unknown mode and a bad yolo' {
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'turbo' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*is not a task delivery mode*'
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'maybe' -StateDir $script:state } |
            Should -Throw "*-Yolo must be on or off (got 'maybe')*"
    }

    It 'refuses a missing meta and a missing state dir' {
        { Invoke-FmPromote -TaskId 'ghost' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*no meta for task ghost*'
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' `
                -StateDir (Join-Path $TestDrive 'no-such-state') } | Should -Throw '*state dir not found*'
    }

    It 'refuses while another lifecycle action holds the task control lock' {
        $held = New-FmDeliveryLock -Path (Get-FmDeliveryControlLockPath -StateDir $script:state -TaskId 'scout1')
        $held.Acquired | Should -BeTrue
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*another lifecycle action is already running for task scout1; nothing was changed*'
        @(Get-FmSessionFileLines -Path (Join-Path $script:state 'scout1.meta')) | Should -Contain 'kind=scout'
    }

    It 'releases both locks after a successful promotion and after a refusal' {
        $control = Get-FmDeliveryControlLockPath -StateDir $script:state -TaskId 'scout1'
        $meta = Get-FmDeliveryMetaLockPath -StateDir $script:state -TaskId 'scout1'
        $null = Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' -StateDir $script:state
        Test-Path -LiteralPath $control | Should -BeFalse
        Test-Path -LiteralPath $meta | Should -BeFalse

        # The second promotion refuses (it is now a ship task) and must still release.
        { Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } | Should -Throw
        Test-Path -LiteralPath $control | Should -BeFalse
        Test-Path -LiteralPath $meta | Should -BeFalse
    }

    It 'changes nothing under -WhatIf' {
        Invoke-FmPromote -TaskId 'scout1' -Mode 'local-only' -Yolo 'off' -StateDir $script:state -WhatIf |
            Should -BeNullOrEmpty
        @(Get-FmSessionFileLines -Path (Join-Path $script:state 'scout1.meta')) | Should -Contain 'kind=scout'
    }

    It 'refuses an invalid task id' {
        { Invoke-FmPromote -TaskId '.hidden' -Mode 'local-only' -Yolo 'off' -StateDir $script:state } |
            Should -Throw '*invalid task id*'
    }
}
