#requires -Version 7.0
# Pester 5+/6 tests for the guarded GitHub landing path.
#
# `gh` is mocked, because every call it makes reaches the network and one of
# them merges a pull request. What is NOT mocked is the judgement: the check
# rollups below are the real shapes GitHub returns, and each refusal is asserted
# against the words an operator would act on.
#
# Refusals are tested at least as thoroughly as successes. This command exists
# entirely to refuse things, so a refusal without a test is the defect.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    # The whole tree in the loader's own order: a partial load just picks a
    # different arbitrary set of owners to be absent.
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # Pester 6 has no "call the original" for a filtered mock, so the real
    # implementation is captured and an unfiltered default delegates to it.
    # Without that, mocking `gh` would also mock `git`.
    $script:RealChildProcess = ${function:Invoke-FmChildProcess}

    $script:Head = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
    $script:Url = 'https://github.com/owner/repo/pull/12'

    function New-CheckRun {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A pure Pester value builder: it composes a fixture object and changes nothing, so -WhatIf would leave the test asserting against a value that was never built.')]
        param(
            [string]$Name,
            [string]$Status = 'COMPLETED',
            [string]$Conclusion = 'SUCCESS',
            [AllowEmptyString()][string]$StartedAt = '2026-09-16T10:00:00Z'
        )
        [ordered]@{
            __typename = 'CheckRun'; name = $Name; status = $Status
            conclusion = $Conclusion; startedAt = $StartedAt
        }
    }

    function New-StatusContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A pure Pester value builder: it composes a fixture object and changes nothing, so -WhatIf would leave the test asserting against a value that was never built.')]
        param([string]$Context, [string]$State = 'SUCCESS')
        [ordered]@{ __typename = 'StatusContext'; context = $Context; state = $State }
    }

    function New-PrViewJson {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A pure Pester value builder: it composes a fixture object and changes nothing, so -WhatIf would leave the test asserting against a value that was never built.')]
        param(
            [string]$State = 'OPEN',
            [bool]$Draft = $false,
            [string]$Mergeable = 'MERGEABLE',
            [string]$MergeState = 'CLEAN',
            [string]$HeadOid = '',
            [string]$Base = 'main',
            [AllowEmptyCollection()][object[]]$Checks = @()
        )
        if (-not $HeadOid) { $HeadOid = $script:Head }
        [ordered]@{
            state             = $State
            isDraft           = $Draft
            mergeable         = $Mergeable
            mergeStateStatus  = $MergeState
            headRefOid        = $HeadOid
            baseRefName       = $Base
            statusCheckRollup = @($Checks)
        } | ConvertTo-Json -Depth 8
    }

    function New-GraphJson {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A pure Pester value builder: it composes a fixture object and changes nothing, so -WhatIf would leave the test asserting against a value that was never built.')]
        param([bool]$Merged = $true, [bool]$Queued = $false, [string]$State = 'MERGED')
        [ordered]@{
            data = [ordered]@{
                repository = [ordered]@{
                    pullRequest = [ordered]@{ state = $State; merged = $Merged; isInMergeQueue = $Queued }
                }
            }
        } | ConvertTo-Json -Depth 8
    }

    # Parse a view the way the production read does, so the rollup tests judge
    # exactly the object shape ConvertFrom-Json actually produces.
    function ConvertTo-PrView {
        param([Parameter(Mandatory)][string]$Json)
        ConvertFrom-FmJsonSafe -Text $Json
    }

    function New-ChildProcessResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A pure Pester value builder: it composes a fixture object and changes nothing, so -WhatIf would leave the test asserting against a value that was never built.')]
        param([bool]$Ok = $true, [int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '')
        [pscustomobject]@{
            Ok       = $Ok; ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr
            Combined = ($StdOut + $StdErr); TimedOut = $false
        }
    }

    # One fixture home per test, so no test can see another's state or wake queue.
    function New-TestFixture {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A Pester fixture builder: it writes only into TestDrive.')]
        [CmdletBinding()]
        param(
            [string]$TaskId = 'task1',
            [string]$Mode = 'direct-PR',
            [string]$Yolo = 'off',
            [AllowEmptyCollection()][string[]]$ExtraMeta = @()
        )
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $state = Join-Path $root 'state'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $lines = @("id=$TaskId", 'kind=ship', "mode=$Mode", "yolo=$Yolo") + @($ExtraMeta)
        $meta = Join-Path $state "$TaskId.meta"
        [System.IO.File]::WriteAllText($meta, (($lines -join "`n") + "`n"))
        [pscustomobject]@{ Root = $root; State = $state; TaskId = $TaskId; Meta = $meta }
    }

    function Get-WakePayload {
        param([Parameter(Mandatory)][string]$State)
        $queue = Join-Path $State '.wake-queue'
        if (-not (Test-Path -LiteralPath $queue -PathType Leaf)) { return @() }
        @([System.IO.File]::ReadAllText($queue) -split "`n" | Where-Object { $_ } | ForEach-Object {
                ($_ -split "`t")[4]
            })
    }

    # This file's commands run the supervision guard and the wake queue against
    # the home they resolve, and with nothing pinned that is this checkout - in
    # the primary checkout, the captain's own state/. So it runs in an empty home.
    $script:SavedHomeEnv = @{}
    foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE', 'STATE', 'FM_CONFIG_OVERRIDE', 'FM_WAKE_QUEUE', 'FM_WAKE_QUEUE_LOCK')) {
        $script:SavedHomeEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:FM_HOME = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Path $env:FM_HOME -Force | Out-Null
}

AfterAll {
    foreach ($name in $script:SavedHomeEnv.Keys) {
        if ($null -eq $script:SavedHomeEnv[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$name" -Value $script:SavedHomeEnv[$name]
        }
    }
}

Describe 'the home this file runs in' {
    It 'is under TestDrive, never the checkout, because these commands write wake records' {
        (Get-FmWakeContext).State | Should -BeLike "$TestDrive*"
    }
}

# =============================================================================
# The pull request's identity
# =============================================================================

Describe 'Get-FmPrMergeUrlParts' {
    It 'splits a canonical pull request URL' {
        $parts = Get-FmPrMergeUrlParts -Url 'https://github.com/owner/repo.name/pull/1234'
        $parts.HostName | Should -Be 'github.com'
        $parts.Owner | Should -Be 'owner'
        $parts.Repository | Should -Be 'repo.name'
        $parts.Number | Should -Be 1234
        $parts.Url | Should -Be 'https://github.com/owner/repo.name/pull/1234'
    }

    It 'keeps a GitHub Enterprise host rather than assuming github.com' {
        (Get-FmPrMergeUrlParts -Url 'https://github.example.test/o/r/pull/7').HostName |
            Should -Be 'github.example.test'
    }

    It 'normalises one trailing slash, because that is how a browser hands it over' {
        (Get-FmPrMergeUrlParts -Url 'https://github.com/o/r/pull/7/').Url |
            Should -Be 'https://github.com/o/r/pull/7'
    }

    It 'refuses everything that is not exactly a pull request URL' {
        # Each of these is a URL a merge must never be attempted against: an
        # unencrypted scheme, a deeper page, an issue, a GitLab merge request,
        # a zero number, and a number with a suffix.
        foreach ($bad in @(
                '', 'not a url', '12', 'owner/repo#12',
                'http://github.com/o/r/pull/7',
                'https://github.com/o/r/pull/7/files',
                'https://github.com/o/r/issues/7',
                'https://gitlab.com/o/r/-/merge_requests/7',
                'https://github.com/o/r/pull/0',
                'https://github.com/o/r/pull/7x')) {
            Get-FmPrMergeUrlParts -Url $bad | Should -BeNullOrEmpty -Because "'$bad' is not a pull request URL"
        }
    }
}

# =============================================================================
# The forge arguments a caller may not supply
# =============================================================================

Describe 'Test-FmPrMergeForgeArgument' {
    It 'accepts an ordinary argument' {
        @(Test-FmPrMergeForgeArgument -Argument @('--body', 'landing it')).Count | Should -Be 0
    }

    It 'refuses a repository or head override even when the caller is attended' {
        # These two decide WHICH repository and WHICH commit the merge lands, and
        # both come from the verified live read. No flag re-enables them.
        foreach ($bad in @('--repo', '-R', '--match-head-commit', '--sha')) {
            @(Test-FmPrMergeForgeArgument -Argument @($bad, 'x') -AttendedOverride).Count |
                Should -Be 1 -Because "$bad must be refused even with -AttendedOverride"
        }
        @(Test-FmPrMergeForgeArgument -Argument @('--repo=other/thing'))[0] |
            Should -BeLike '*--repo is not allowed here*'
    }

    It 'refuses auto, admin and branch deletion unless the caller is attended' {
        foreach ($flag in @('--auto', '--admin', '--delete-branch', '-d')) {
            @(Test-FmPrMergeForgeArgument -Argument @($flag)).Count |
                Should -Be 1 -Because "$flag needs -AttendedOverride"
            @(Test-FmPrMergeForgeArgument -Argument @($flag) -AttendedOverride).Count |
                Should -Be 0 -Because "-AttendedOverride is what re-enables $flag"
        }
    }

    It 'reads a bundled short-option cluster, which is how the guard is walked past' {
        # gh parses -sd as squash AND delete-branch. A check that only looked at
        # whole tokens would wave both of these through.
        $refusals = @(Test-FmPrMergeForgeArgument -Argument @('-dR'))
        $refusals.Count | Should -Be 2
        ($refusals -join ' ') | Should -BeLike '*--repo*'
        ($refusals -join ' ') | Should -BeLike '*--delete-branch*'
        # Attended clears the delete-branch half and never the repo half.
        $attended = @(Test-FmPrMergeForgeArgument -Argument @('-dR') -AttendedOverride)
        $attended.Count | Should -Be 1
        $attended[0] | Should -BeLike '*--repo*'
    }

    It 'refuses a second merge method rather than letting two compete' {
        foreach ($flag in @('--squash', '-s', '--merge', '-m', '--rebase', '-r')) {
            @(Test-FmPrMergeForgeArgument -Argument @($flag))[0] |
                Should -BeLike '*pass it as -Method*'
        }
    }

    It 'tells gh''s -r from its -R, because a PowerShell hash key does not' {
        # A hashtable matches keys case-INSENSITIVELY by default, so `-r`
        # (rebase) looked up `-R` (repo) and this guard refused an ordinary
        # rebase merge with a message about the repository. They are different
        # flags to gh, so they have to be different keys here.
        @(Test-FmPrMergeForgeArgument -Argument @('-r'))[0] | Should -BeLike '*merge method*'
        @(Test-FmPrMergeForgeArgument -Argument @('-R', 'o/r'))[0] | Should -BeLike '*repository comes from*'
        # And the same distinction inside a bundled cluster.
        @(Test-FmPrMergeForgeArgument -Argument @('-dr') -AttendedOverride).Count | Should -Be 0
        @(Test-FmPrMergeForgeArgument -Argument @('-dR') -AttendedOverride)[0] | Should -BeLike '*repository comes from*'
    }

    It 'reports every bad argument at once, not just the first' {
        @(Test-FmPrMergeForgeArgument -Argument @('--repo', 'o/r', '--admin', '--auto')).Count | Should -Be 3
    }
}

# =============================================================================
# What makes a check green - the supersession rule
# =============================================================================

Describe 'Get-FmPrMergeSettledAt' {
    It 'accepts the [datetime] ConvertFrom-Json actually hands back' {
        # THE TRAP THIS EXISTS FOR. The bash tests startedAt as a STRING of an
        # exact shape, because jq gives it one. ConvertFrom-Json does not: it
        # recognises the timestamp and returns a [datetime], so a straight port
        # of the string test rejects every real timestamp and the supersession
        # rule silently never fires.
        $parsed = ConvertFrom-FmJsonSafe -Text '{"startedAt":"2026-09-16T10:00:00Z"}'
        $parsed.startedAt | Should -BeOfType [datetime]
        (Get-FmPrMergeSettledAt -Value $parsed.startedAt) | Should -Be ([datetime]::new(2026, 9, 16, 10, 0, 0, [System.DateTimeKind]::Utc))
    }

    It 'normalises an offset to UTC rather than to the machine''s clock' {
        (Get-FmPrMergeSettledAt -Value ([System.DateTimeOffset]::new(2026, 9, 16, 12, 0, 0, [timespan]::FromHours(2)))) |
            Should -Be ([datetime]::new(2026, 9, 16, 10, 0, 0, [System.DateTimeKind]::Utc))
    }

    It 'still reads a raw UTC string, so the rule does not depend on one parser' {
        (Get-FmPrMergeSettledAt -Value '2026-09-16T10:00:00Z') |
            Should -Be ([datetime]::new(2026, 9, 16, 10, 0, 0, [System.DateTimeKind]::Utc))
        # Sub-second precision is orderable, so it is kept rather than refused.
        (Get-FmPrMergeSettledAt -Value '2026-09-16T10:00:00.250Z') | Should -Not -BeNullOrEmpty
    }

    It 'answers nothing for anything that is not an instant' {
        foreach ($bad in @($null, '', 'yesterday', '2026-09-16', 'T10:00:00Z', '2026-09-16T10:00:00')) {
            Get-FmPrMergeSettledAt -Value $bad | Should -BeNullOrEmpty -Because "'$bad' is not an instant"
        }
    }
}

Describe 'Get-FmPrMergeCheckVerdict' {
    It 'reads a pull request with no checks at all as green' {
        $verdict = Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson))
        $verdict.Readable | Should -BeTrue
        $verdict.NotGreen.Count | Should -Be 0
    }

    It 'reports a missing rollup as UNREADABLE, never as green' {
        # The difference matters: "no checks" merges, "could not read the checks"
        # must not.
        foreach ($broken in @('{"state":"OPEN"}', '{"statusCheckRollup":null}', '{"statusCheckRollup":"none"}')) {
            (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json $broken)).Readable |
                Should -BeFalse -Because "$broken carries no readable rollup"
        }
    }

    It 'counts NEUTRAL and SKIPPED as green and FAILURE as red' {
        $checks = @(
            (New-CheckRun -Name 'neutral' -Conclusion 'NEUTRAL'),
            (New-CheckRun -Name 'skipped' -Conclusion 'SKIPPED'),
            (New-CheckRun -Name 'broken' -Conclusion 'FAILURE'))
        $verdict = Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))
        $verdict.NotGreen | Should -Be @('broken')
    }

    It 'clears a failed run that a LATER run of the same name passed' {
        # THE DEFECT THIS RULE EXISTS FOR. GitHub leaves the cancelled or failed
        # run in the rollup beside the passing re-run it triggered, so judging
        # each run on its own reports the check red for ever after one failure -
        # and a gate that refuses green work is a gate people go round.
        $checks = @(
            (New-CheckRun -Name 'build' -Conclusion 'FAILURE' -StartedAt '2026-09-16T10:00:00Z'),
            (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T11:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen.Count |
            Should -Be 0
    }

    It 'keeps a check red when the failure is the NEWER run' {
        $checks = @(
            (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T10:00:00Z'),
            (New-CheckRun -Name 'build' -Conclusion 'FAILURE' -StartedAt '2026-09-16T11:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('build')
    }

    It 'keeps a check red while a failed run is still in flight' {
        # An IN_PROGRESS run may yet be the last word, so an earlier pass does
        # not settle the question.
        $checks = @(
            (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T12:00:00Z'),
            (New-CheckRun -Name 'build' -Status 'IN_PROGRESS' -Conclusion '' -StartedAt '2026-09-16T10:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('build')
    }

    It 'keeps a check red when a failed run carries no usable timestamp' {
        # Nothing can be ordered against an unparseable time, so nothing may be
        # said to have replaced it.
        foreach ($stamp in @('', 'yesterday', 'T10:00:00Z', '1789456123')) {
            $checks = @(
                (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T12:00:00Z'),
                (New-CheckRun -Name 'build' -Conclusion 'FAILURE' -StartedAt $stamp))
            (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
                Should -Be @('build') -Because "'$stamp' is not an orderable timestamp"
        }
    }

    It 'keeps a check red when no passing run of that name carries a timestamp' {
        $checks = @(
            (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt ''),
            (New-CheckRun -Name 'build' -Conclusion 'FAILURE' -StartedAt '2026-09-16T10:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('build')
    }

    It 'never lets one check clear another check''s failure' {
        $checks = @(
            (New-CheckRun -Name 'lint' -Conclusion 'FAILURE' -StartedAt '2026-09-16T10:00:00Z'),
            (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T11:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('lint')
    }

    It 'never lets a check run supersede a legacy status context' {
        # A status context has no runs to replace it, so a later green check run
        # of the same name says nothing about it.
        $checks = @(
            (New-StatusContext -Context 'ci/legacy' -State 'FAILURE'),
            (New-CheckRun -Name 'ci/legacy' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T23:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('ci/legacy')
    }

    It 'never groups two UNNAMED check runs together' {
        # An empty name is not evidence that two runs are the same check, so a
        # green unnamed run must not clear a red one.
        $checks = @(
            (New-CheckRun -Name '' -Conclusion 'FAILURE' -StartedAt '2026-09-16T10:00:00Z'),
            (New-CheckRun -Name '' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T11:00:00Z'))
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks $checks))).NotGreen |
            Should -Be @('(unnamed check)')
    }

    It 'names an unnamed status context rather than reporting an empty string' {
        (Get-FmPrMergeCheckVerdict -View (ConvertTo-PrView -Json (New-PrViewJson -Checks @(
                        (New-StatusContext -Context '' -State 'ERROR'))))).NotGreen |
            Should -Be @('(unnamed check)')
    }
}

# =============================================================================
# The live pre-merge read
# =============================================================================

Describe 'Test-FmPrMergeReady' {
    BeforeEach {
        $script:GhView = New-PrViewJson
        $script:GhViewOk = $true
        Mock Invoke-FmChildProcess {
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmChildProcess {
            if (-not $script:GhViewOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr 'gh: not found') }
            New-ChildProcessResult -StdOut $script:GhView
        } -ParameterFilter { $FilePath -eq 'gh' }
    }

    It 'passes an open, mergeable, green pull request and binds its head' {
        $verdict = Test-FmPrMergeReady -Url $script:Url
        $verdict.Ready | Should -BeTrue
        $verdict.Unreadable | Should -BeFalse
        $verdict.Head | Should -Be $script:Head
        $verdict.Base | Should -Be 'main'
    }

    It 'refuses each pre-merge condition on its own' {
        $cases = @(
            @{ Json = (New-PrViewJson -State 'CLOSED'); Like = '*state is "CLOSED", not open*' }
            @{ Json = (New-PrViewJson -State 'MERGED'); Like = '*state is "MERGED", not open*' }
            @{ Json = (New-PrViewJson -Draft $true); Like = '*the pull request is a draft*' }
            @{ Json = (New-PrViewJson -Mergeable 'CONFLICTING'); Like = '*mergeable is "CONFLICTING", not MERGEABLE*' }
            @{ Json = (New-PrViewJson -MergeState 'DIRTY'); Like = '*mergeStateStatus is DIRTY*' }
            @{ Json = (New-PrViewJson -Checks @((New-CheckRun -Name 'build' -Conclusion 'FAILURE'))); Like = "*check 'build' is not green*" }
        )
        foreach ($case in $cases) {
            $script:GhView = $case.Json
            $verdict = Test-FmPrMergeReady -Url $script:Url
            $verdict.Ready | Should -BeFalse
            $verdict.Unreadable | Should -BeFalse
            ($verdict.Refusals -join "`n") | Should -BeLike $case.Like
        }
    }

    It 'reports EVERY failing condition, not only the first' {
        # A pull request that is closed, a draft, conflicted and red costs four
        # round trips to learn about one refusal at a time.
        $script:GhView = New-PrViewJson -State 'CLOSED' -Draft $true -Mergeable 'CONFLICTING' -MergeState 'DIRTY' `
            -Checks @((New-CheckRun -Name 'build' -Conclusion 'FAILURE'))
        (Test-FmPrMergeReady -Url $script:Url).Refusals.Count | Should -Be 5
    }

    It 'separates UNREADABLE from refused, because the operator does something different about each' {
        $script:GhViewOk = $false
        $verdict = Test-FmPrMergeReady -Url $script:Url
        $verdict.Unreadable | Should -BeTrue
        ($verdict.Refusals -join ' ') | Should -BeLike '*could not read the GitHub pull request state*'
    }

    It 'treats a readable answer with no usable head or base as unreadable, not as a refusal' {
        # There is nothing to bind a merge to and nothing to refuse ABOUT, so
        # this is a failed read however complete the rest of the payload looks.
        foreach ($json in @(
                (New-PrViewJson -HeadOid 'not-a-sha'),
                (New-PrViewJson -HeadOid 'a1b2'),
                (New-PrViewJson -Base ''))) {
            $script:GhView = $json
            (Test-FmPrMergeReady -Url $script:Url).Unreadable | Should -BeTrue
        }
    }

    It 'waives only the check it was given, by exact name' {
        $script:GhView = New-PrViewJson -Checks @(
            (New-CheckRun -Name 'flaky' -Conclusion 'FAILURE'),
            (New-CheckRun -Name 'flaky-too' -Conclusion 'FAILURE'))
        $verdict = Test-FmPrMergeReady -Url $script:Url -AllowRed @('flaky')
        $verdict.Ready | Should -BeFalse
        $verdict.Waived | Should -Be @('flaky')
        $verdict.NotGreen | Should -Be @('flaky-too')

        (Test-FmPrMergeReady -Url $script:Url -AllowRed @('flaky', 'flaky-too')).Ready | Should -BeTrue
    }

    It 'never waives by prefix, which is how one waiver becomes a standing one' {
        $script:GhView = New-PrViewJson -Checks @((New-CheckRun -Name 'build-windows' -Conclusion 'FAILURE'))
        (Test-FmPrMergeReady -Url $script:Url -AllowRed @('build')).Ready | Should -BeFalse
    }
}

# =============================================================================
# Reading GitHub back
# =============================================================================

Describe 'Get-FmPrMergeOutcome' {
    BeforeEach {
        $script:GraphJson = New-GraphJson -Merged $true
        $script:GraphOk = $true
        $script:StateJson = '{"state":"OPEN"}'
        $script:StateOk = $true
        Mock Invoke-FmChildProcess {
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmChildProcess {
            if (@($ArgumentList)[0] -eq 'api') {
                if (-not $script:GraphOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1) }
                return (New-ChildProcessResult -StdOut $script:GraphJson)
            }
            if (-not $script:StateOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1) }
            New-ChildProcessResult -StdOut $script:StateJson
        } -ParameterFilter { $FilePath -eq 'gh' }

        $script:Parts = Get-FmPrMergeUrlParts -Url $script:Url
    }

    It 'reports a merged pull request, with the queue observed' {
        $outcome = Get-FmPrMergeOutcome -Parts $script:Parts
        $outcome.Merged | Should -BeTrue
        $outcome.QueueObserved | Should -BeTrue
        $outcome.Source | Should -Be 'graphql'
    }

    It 'tells a QUEUED pull request from a landed one' {
        # The whole reason the GraphQL read exists: `gh pr view --json` has no
        # isInMergeQueue field, so nothing else can draw this distinction.
        $script:GraphJson = New-GraphJson -Merged $false -Queued $true -State 'OPEN'
        $outcome = Get-FmPrMergeOutcome -Parts $script:Parts
        $outcome.Merged | Should -BeFalse
        $outcome.Queued | Should -BeTrue
    }

    It 'falls back to the plain view when the GraphQL read fails, but only to PROVE a merge' {
        $script:GraphOk = $false
        $script:StateJson = '{"state":"MERGED"}'
        $outcome = Get-FmPrMergeOutcome -Parts $script:Parts
        $outcome.Merged | Should -BeTrue
        $outcome.Source | Should -Be 'view'
        # It cannot see the queue, and says so rather than implying it could.
        $outcome.QueueObserved | Should -BeFalse
    }

    It 'refuses to answer when the fallback cannot prove a merge' {
        # A "not merged" from a read that cannot see the merge queue is an
        # INCOMPLETE answer, not a negative one.
        $script:GraphOk = $false
        foreach ($state in @('{"state":"OPEN"}', '{"state":"CLOSED"}')) {
            $script:StateJson = $state
            Get-FmPrMergeOutcome -Parts $script:Parts | Should -BeNullOrEmpty
        }
        $script:StateOk = $false
        Get-FmPrMergeOutcome -Parts $script:Parts | Should -BeNullOrEmpty
    }

    It 'treats a PARTIAL GraphQL answer as no answer' {
        # An absent `merged` read as $false would turn a landed merge into a
        # refusal, so a payload missing any field falls through instead.
        $script:GraphOk = $true
        $script:StateOk = $false
        foreach ($partial in @(
                '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true}}}}',
                '{"data":{"repository":{"pullRequest":{"merged":true,"isInMergeQueue":false}}}}',
                '{"data":{"repository":{"pullRequest":null}}}',
                'not json at all')) {
            $script:GraphJson = $partial
            Get-FmPrMergeOutcome -Parts $script:Parts | Should -BeNullOrEmpty -Because "$partial is incomplete"
        }
    }
}

# =============================================================================
# One durable notification per verified merge
# =============================================================================

Describe 'Publish-FmPrMergeOutcome' {
    It 'publishes one wake record and marks the merge as reported' {
        $fx = New-TestFixture
        $context = Get-FmWakeContext -State $fx.State
        $notice = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId -PrUrl $script:Url -Context $context
        $notice.Published | Should -BeTrue
        $notice.AlreadyRecorded | Should -BeFalse
        $payloads = @(Get-WakePayload -State $fx.State)
        $payloads.Count | Should -Be 1
        $payloads[0] | Should -Be "check: merge landed: $($fx.TaskId) $($script:Url)"
        Test-Path -LiteralPath (Get-FmPrMergeNotifyPath -StateDir $fx.State -TaskId $fx.TaskId) | Should -BeTrue
    }

    It 'says nothing a second time for the same pull request' {
        # The wake queue de-duplicates only among records still QUEUED, so once
        # a handling turn acknowledges one the key is free again. The marker is
        # what makes once mean once for good.
        $fx = New-TestFixture
        $context = Get-FmWakeContext -State $fx.State
        $null = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId -PrUrl $script:Url -Context $context
        $again = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId -PrUrl $script:Url -Context $context
        $again.AlreadyRecorded | Should -BeTrue
        $again.Published | Should -BeFalse
        @(Get-WakePayload -State $fx.State).Count | Should -Be 1
    }

    It 'still reports a DIFFERENT pull request for the same task' {
        # A reused task id is not a reused merge.
        $fx = New-TestFixture
        $context = Get-FmWakeContext -State $fx.State
        $null = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId -PrUrl $script:Url -Context $context
        $second = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId `
            -PrUrl 'https://github.com/owner/repo/pull/13' -Context $context
        $second.Published | Should -BeTrue
        @(Get-WakePayload -State $fx.State).Count | Should -Be 2
    }

    It 'tags a standing authority and leaves an attended merge untagged' {
        $fx = New-TestFixture
        $context = Get-FmWakeContext -State $fx.State
        $null = Publish-FmPrMergeOutcome -StateDir $fx.State -TaskId $fx.TaskId -PrUrl $script:Url `
            -Authority 'yolo' -Context $context
        @(Get-WakePayload -State $fx.State)[0] | Should -BeLike '* yolo'
    }
}

# =============================================================================
# The command, end to end
# =============================================================================

Describe 'Invoke-FmPrMerge' {
    BeforeEach {
        $script:GhCalls = [System.Collections.Generic.List[object]]::new()
        $script:PlanView = New-PrViewJson
        $script:PlanViewOk = $true
        $script:PlanMergeOk = $true
        $script:PlanMergeExit = 0
        $script:PlanMergeErr = ''
        $script:PlanGraph = New-GraphJson -Merged $true
        $script:PlanGraphOk = $true
        $script:PlanStateOk = $false
        $script:PlanState = '{"state":"OPEN"}'

        Mock Invoke-FmChildProcess {
            $splat = @{ FilePath = $FilePath }
            foreach ($name in @('ArgumentList', 'Environment', 'WorkingDirectory', 'TimeoutSeconds', 'StandardInput')) {
                $value = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $value) { $splat[$name] = $value }
            }
            & $script:RealChildProcess @splat
        }
        Mock Invoke-FmChildProcess {
            $call = @($ArgumentList)
            $script:GhCalls.Add($call)
            if ($call[0] -eq 'api') {
                if (-not $script:PlanGraphOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1) }
                return (New-ChildProcessResult -StdOut $script:PlanGraph)
            }
            if ($call[0] -eq 'pr' -and $call[1] -eq 'merge') {
                if (-not $script:PlanMergeOk) {
                    return (New-ChildProcessResult -Ok $false -ExitCode $script:PlanMergeExit -StdErr $script:PlanMergeErr)
                }
                return (New-ChildProcessResult -StdOut 'Merged pull request #12')
            }
            # `pr view`: the full preflight read, or the state-only fallback.
            $index = [array]::IndexOf($call, '--json')
            if ($index -ge 0 -and $call[$index + 1] -eq 'state') {
                if (-not $script:PlanStateOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1) }
                return (New-ChildProcessResult -StdOut $script:PlanState)
            }
            if (-not $script:PlanViewOk) { return (New-ChildProcessResult -Ok $false -ExitCode 1 -StdErr 'gh: could not resolve') }
            New-ChildProcessResult -StdOut $script:PlanView
        } -ParameterFilter { $FilePath -eq 'gh' }
    }

    Context 'refusals that cost no network call' {
        It 'refuses a task id that is not one' {
            { Invoke-FmPrMerge -TaskId '../escape' -PrUrl $script:Url -StateDir (New-TestFixture).State -Confirm:$false } |
                Should -Throw '*is not a valid task id*'
        }

        It 'refuses a URL that is not a canonical pull request URL, and says where to get one' {
            $fx = New-TestFixture
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl 'github.com/o/r/pull/1' -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*copy it from the worker or the task record rather than composing one*'
            @($script:GhCalls).Count | Should -Be 0
        }

        It 'refuses -AllowRed unless a captain is recorded as asking' {
            # Standing yolo authority may never merge a red pull request, so the
            # waiver takes the switch that records an explicit instruction.
            $fx = New-TestFixture
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -AllowRed @('flaky') -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*-AllowRed needs -AttendedOverride*'
            @($script:GhCalls).Count | Should -Be 0
        }

        It 'refuses a guarded forge argument before anything is read' {
            $fx = New-TestFixture
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -ExtraArgument @('--admin') -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*--admin needs -AttendedOverride*'
            @($script:GhCalls).Count | Should -Be 0
        }

        It 'refuses a task with no meta at all' {
            $fx = New-TestFixture
            { Invoke-FmPrMerge -TaskId 'ghost' -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*no meta for task ghost*'
        }

        It 'refuses a local-only task and names the command that does land one' {
            $fx = New-TestFixture -Mode 'local-only'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*not direct-PR*bin/fm-merge-local.ps1*'
        }

        It 'refuses when gh is not on PATH, before any state is recorded' {
            # A merge that cannot read GitHub must stop before it half-starts.
            $fx = New-TestFixture
            $empty = Join-Path $fx.Root 'no-tools'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $savedPath = $env:PATH
            try {
                $env:PATH = $empty
                { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                    Should -Throw '*gh is not on PATH*'
            } finally {
                $env:PATH = $savedPath
            }
            Get-FmMetaValue -Path $fx.Meta -Key 'pr' | Should -Be ''
        }

        It 'refuses to re-point a task at a different pull request' {
            $fx = New-TestFixture -ExtraMeta @('pr=https://github.com/owner/repo/pull/9')
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*already recorded against https://github.com/owner/repo/pull/9*'
        }
    }

    Context 'the live gate' {
        It 'refuses a red pull request and names the check' {
            $fx = New-TestFixture
            $script:PlanView = New-PrViewJson -Checks @((New-CheckRun -Name 'build' -Conclusion 'FAILURE'))
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*these checks are not green: build*'
            # And it never got as far as a merge.
            @($script:GhCalls | Where-Object { $_[1] -eq 'merge' }).Count | Should -Be 0
        }

        It 'merges when the only red run was replaced by a later passing one' {
            # The end-to-end proof of the supersession rule: without it this
            # perfectly good pull request is refused.
            $fx = New-TestFixture
            $script:PlanView = New-PrViewJson -Checks @(
                (New-CheckRun -Name 'build' -Conclusion 'FAILURE' -StartedAt '2026-09-16T10:00:00Z'),
                (New-CheckRun -Name 'build' -Conclusion 'SUCCESS' -StartedAt '2026-09-16T11:00:00Z'))
            (Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false).Merged |
                Should -BeTrue
        }

        It 'records pr= once the pull request has been READ, even when the gate refuses' {
            # A readable pull request exists, so binding the task to it is safe
            # and makes the record useful to teardown either way.
            $fx = New-TestFixture
            $script:PlanView = New-PrViewJson -State 'CLOSED'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*not open*'
            Get-FmMetaValue -Path $fx.Meta -Key 'pr' | Should -Be $script:Url
        }

        It 'records nothing when the pull request could not be read, because that could be a typo' {
            $fx = New-TestFixture
            $script:PlanViewOk = $false
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*could not read the GitHub pull request state*'
            Get-FmMetaValue -Path $fx.Meta -Key 'pr' | Should -Be ''
        }
    }

    Context 'the merge itself' {
        It 'binds the merge to the head it verified' {
            # THE RACE THIS CLOSES: a push landing between the read and the merge
            # would otherwise land commits nothing checked.
            $fx = New-TestFixture
            $null = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $merge = @($script:GhCalls | Where-Object { $_[1] -eq 'merge' })[0]
            $merge | Should -Contain '--match-head-commit'
            $merge[([array]::IndexOf($merge, '--match-head-commit') + 1)] | Should -Be $script:Head
        }

        It 'selects the method itself rather than inheriting gh''s default' {
            $fx = New-TestFixture
            $null = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            @($script:GhCalls | Where-Object { $_[1] -eq 'merge' })[0] | Should -Contain '--squash'

            $other = New-TestFixture -TaskId 'task2'
            $null = Invoke-FmPrMerge -TaskId 'task2' -PrUrl $script:Url -Method 'rebase' -StateDir $other.State -Confirm:$false
            @($script:GhCalls | Where-Object { $_[1] -eq 'merge' })[1] | Should -Contain '--rebase'
        }

        It 'quotes the forge''s own words when gh refuses the merge' {
            # Never distilled into a phrase of ours: the real reason is the part
            # that gets lost.
            $fx = New-TestFixture
            $script:PlanMergeOk = $false
            $script:PlanMergeExit = 1
            $script:PlanMergeErr = 'Head branch was modified. Review and try the merge again.'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*Head branch was modified*'
        }

        It 'changes nothing when -WhatIf is passed' {
            $fx = New-TestFixture
            $result = & { $WhatIfPreference = $true; Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State }
            $result | Should -BeNullOrEmpty
            @($script:GhCalls | Where-Object { $_[1] -eq 'merge' }).Count | Should -Be 0
        }
    }

    Context 'saying merged only when GitHub says merged' {
        It 'returns a merge only after GitHub confirms it, and reports it once' {
            $fx = New-TestFixture
            $result = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $result.Merged | Should -BeTrue
            $result.Head | Should -Be $script:Head
            $result.BaseBranch | Should -Be 'main'
            $result.Notified | Should -Be 'published'
            $result.Message | Should -BeLike '*GitHub confirms state=MERGED*'
            @(Get-WakePayload -State $fx.State).Count | Should -Be 1
            Get-FmMetaValue -Path $fx.Meta -Key 'pr' | Should -Be $script:Url
        }

        It 'refuses to call a QUEUED pull request merged' {
            # gh returns success for a merge-queue entry too. Nothing has landed.
            $fx = New-TestFixture
            $script:PlanGraph = New-GraphJson -Merged $false -Queued $true -State 'OPEN'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*in the merge queue, not merged*'
            @(Get-WakePayload -State $fx.State).Count | Should -Be 0
        }

        It 'refuses when gh succeeded but GitHub reports nothing landed' {
            $fx = New-TestFixture
            $script:PlanGraph = New-GraphJson -Merged $false -Queued $false -State 'OPEN'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw '*state=OPEN and merged=false*'
        }

        It 'says loudly that it does not know, rather than guessing, when the read back fails' {
            # The merge may well have landed. This is the one case where saying
            # nothing is worse than saying too much.
            $fx = New-TestFixture
            $script:PlanGraphOk = $false
            $script:PlanStateOk = $false
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                Should -Throw "*GitHub's state could not be read back*"
            @(Get-WakePayload -State $fx.State).Count | Should -Be 0
        }

        It 'accepts the plain-view fallback when it proves the merge' {
            $fx = New-TestFixture
            $script:PlanGraphOk = $false
            $script:PlanStateOk = $true
            $script:PlanState = '{"state":"MERGED"}'
            $result = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $result.Merged | Should -BeTrue
            $result.QueueObserved | Should -BeFalse
        }

        It 'reports the standing authority the TASK recorded, never one it was told' {
            $fx = New-TestFixture -Yolo 'on'
            $result = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $result.Authority | Should -Be 'yolo'
            @(Get-WakePayload -State $fx.State)[0] | Should -BeLike '* yolo'
        }

        It 'does not wake the captain twice for one merge' {
            $fx = New-TestFixture
            $null = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $again = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false
            $again.Notified | Should -Be 'already-recorded'
            @(Get-WakePayload -State $fx.State).Count | Should -Be 1
        }

        It 'waives a named red check only when a captain asked, and records what it waived' {
            $fx = New-TestFixture
            $script:PlanView = New-PrViewJson -Checks @((New-CheckRun -Name 'flaky' -Conclusion 'FAILURE'))
            $result = Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -AllowRed @('flaky') `
                -AttendedOverride -StateDir $fx.State -Confirm:$false
            $result.Merged | Should -BeTrue
            $result.Waived | Should -Be @('flaky')
            $result.Message | Should -BeLike '*waived: flaky*'
        }
    }

    Context 'the per-task interlock' {
        It 'refuses a second lifecycle action against the same task' {
            $fx = New-TestFixture
            $held = Request-FmLock -Path (Get-FmDeliveryControlLockPath -StateDir $fx.State -TaskId $fx.TaskId) -Role 'promote'
            try {
                { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } |
                    Should -Throw '*another lifecycle action is already running*'
            } finally {
                $null = Unlock-FmLock -Lock $held -Confirm:$false
            }
        }

        It 'releases the lock even when the merge is refused' {
            # A refused merge that left the task locked would wedge every later
            # lifecycle action against it.
            $fx = New-TestFixture
            $script:PlanView = New-PrViewJson -State 'CLOSED'
            { Invoke-FmPrMerge -TaskId $fx.TaskId -PrUrl $script:Url -StateDir $fx.State -Confirm:$false } | Should -Throw
            $lock = Request-FmLock -Path (Get-FmDeliveryControlLockPath -StateDir $fx.State -TaskId $fx.TaskId) -Role 'probe'
            $lock | Should -Not -BeNullOrEmpty
            $null = Unlock-FmLock -Lock $lock -Confirm:$false
        }
    }
}
