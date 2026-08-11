#requires -Version 7.0
# Pester 5+/6 tests for the herdr adapter and the backend-neutral layer it
# carries (task metadata, selectors, endpoint validation, control tables).
#
# No test here starts, stops, or otherwise drives a real herdr server: every
# CLI call is mocked, which is both a safety requirement of this task and the
# only way these paths can be exercised on a machine with no herdr session.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmBackendHerdr.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmWorktree.ps1')

    function New-FakeJson {
        param([Parameter(Mandatory)][hashtable]$Body)
        $Body | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    }
}

Describe 'Split-FmHerdrTarget' {
    It 'splits on the FIRST colon only, because a pane id contains one' {
        $parsed = Split-FmHerdrTarget -Target 'default:w1:p2'
        $parsed.Session | Should -Be 'default'
        $parsed.PaneId | Should -Be 'w1:p2'
    }

    It 'handles a session name that itself begins with fm-' {
        $parsed = Split-FmHerdrTarget -Target 'fm-lab:w3:p9'
        $parsed.Session | Should -Be 'fm-lab'
        $parsed.PaneId | Should -Be 'w3:p9'
    }

    It 'refuses a malformed target' {
        Split-FmHerdrTarget -Target 'nocolon' | Should -BeNullOrEmpty
        Split-FmHerdrTarget -Target ':leading' | Should -BeNullOrEmpty
        Split-FmHerdrTarget -Target 'trailing:' | Should -BeNullOrEmpty
        Split-FmHerdrTarget -Target '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-FmHerdrKey' {
    It 'normalizes firstmate key names onto herdr names' {
        ConvertTo-FmHerdrKey -Key 'Enter' | Should -Be 'enter'
        ConvertTo-FmHerdrKey -Key 'Escape' | Should -Be 'escape'
        ConvertTo-FmHerdrKey -Key 'esc' | Should -Be 'escape'
        ConvertTo-FmHerdrKey -Key 'C-c' | Should -Be 'ctrl+c'
        ConvertTo-FmHerdrKey -Key 'Ctrl+C' | Should -Be 'ctrl+c'
        ConvertTo-FmHerdrKey -Key 'C-u' | Should -Be 'ctrl+u'
    }

    It 'passes an unknown key through unchanged rather than guessing' {
        ConvertTo-FmHerdrKey -Key 'F5' | Should -Be 'F5'
    }
}

Describe 'agent-status classification' {
    It 'maps a blocked agent to idle for the watcher' {
        # A blocked agent is stuck waiting on the human, not grinding, so the
        # watcher must see it rather than have it suppressed as busy.
        ConvertTo-FmHerdrBusyState -AgentStatus 'blocked' | Should -Be 'idle'
        ConvertTo-FmHerdrBusyState -AgentStatus 'working' | Should -Be 'busy'
        ConvertTo-FmHerdrBusyState -AgentStatus 'idle' | Should -Be 'idle'
        ConvertTo-FmHerdrBusyState -AgentStatus 'done' | Should -Be 'idle'
    }

    It 'maps a blocked agent to busy for submit confirmation' {
        # The opposite direction, deliberately: a blocked agent HAS taken the
        # input, so the submit landed.
        ConvertTo-FmHerdrSubmitState -AgentStatus 'blocked' | Should -Be 'busy'
        ConvertTo-FmHerdrSubmitState -AgentStatus 'working' | Should -Be 'busy'
        ConvertTo-FmHerdrSubmitState -AgentStatus 'idle' | Should -Be 'idle'
    }

    It 'reports an unreadable status as unknown in both views' {
        ConvertTo-FmHerdrBusyState -AgentStatus '' | Should -Be 'unknown'
        ConvertTo-FmHerdrSubmitState -AgentStatus 'nonsense' | Should -Be 'unknown'
    }
}

Describe 'Get-FmJsonValue' {
    It 'reads a dotted path' {
        $json = New-FakeJson @{ result = @{ pane = @{ pane_id = 'w1:p2' } } }
        Get-FmJsonValue -InputObject $json -Path 'result.pane.pane_id' | Should -Be 'w1:p2'
    }

    It 'returns null for a missing hop instead of throwing under StrictMode' {
        $json = New-FakeJson @{ result = @{} }
        Get-FmJsonValue -InputObject $json -Path 'result.pane.pane_id' | Should -BeNullOrEmpty
        Get-FmJsonValue -InputObject $null -Path 'a.b' | Should -BeNullOrEmpty
    }
}

Describe 'Get-FmHerdrWorkspaceLabel' {
    It 'resolves the primary home to the constant firstmate label' {
        Get-FmHerdrWorkspaceLabel -HomePath (Join-Path $TestDrive 'primary') | Should -Be 'firstmate'
    }

    It 'resolves a seeded secondmate home to its own label' {
        $home2 = Join-Path $TestDrive 'sm'
        New-Item -ItemType Directory -Path $home2 | Out-Null
        Set-Content -LiteralPath (Join-Path $home2 '.fm-secondmate-home') -Value "sm-alpha`n" -NoNewline
        Get-FmHerdrWorkspaceLabel -HomePath $home2 | Should -Be '2ndmate-sm-alpha'
    }
}

Describe 'pane and agent state classification' {
    It 'classifies a structured pane_not_found as dead' {
        Mock Invoke-FmHerdrCliJson { New-FakeJson @{ error = @{ code = 'pane_not_found' } } }
        Get-FmHerdrPanePresenceState -Session 'default' -PaneId 'w1:p2' | Should -Be 'dead'
    }

    It 'classifies a round-tripping pane id as present' {
        Mock Invoke-FmHerdrCliJson { New-FakeJson @{ result = @{ pane = @{ pane_id = 'w1:p2' } } } }
        Get-FmHerdrPanePresenceState -Session 'default' -PaneId 'w1:p2' | Should -Be 'present'
    }

    It 'classifies any other error, or a non-round-tripping id, as unknown' {
        Mock Invoke-FmHerdrCliJson { New-FakeJson @{ error = @{ code = 'server_error' } } }
        Get-FmHerdrPanePresenceState -Session 'default' -PaneId 'w1:p2' | Should -Be 'unknown'

        Mock Invoke-FmHerdrCliJson { New-FakeJson @{ result = @{ pane = @{ pane_id = 'w9:p9' } } } }
        Get-FmHerdrPanePresenceState -Session 'default' -PaneId 'w1:p2' | Should -Be 'unknown'
    }

    It 'reports a live pane with no registered agent as no-agent' {
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'pane') { return New-FakeJson @{ result = @{ pane = @{ pane_id = 'w1:p2' } } } }
            New-FakeJson @{ error = @{ code = 'agent_not_found' } }
        }
        Get-FmHerdrPaneAgentState -Session 'default' -PaneId 'w1:p2' | Should -Be 'no-agent'
    }

    It 'reports any registered agent status as live, including idle and blocked' {
        foreach ($status in @('working', 'idle', 'done', 'blocked')) {
            $paneBody = New-FakeJson @{ result = @{ pane = @{ pane_id = 'w1:p2' } } }
            $agentBody = New-FakeJson @{ result = @{ agent = @{ agent_status = $status } } }
            Mock Invoke-FmHerdrCliJson {
                param($Session, $Arguments)
                if ($Arguments[0] -eq 'pane') { return $paneBody }
                $agentBody
            }.GetNewClosure()
            Get-FmHerdrPaneAgentState -Session 'default' -PaneId 'w1:p2' | Should -Be 'live'
        }
    }

    It 'maps pane states onto the recovery-grade vocabulary' {
        Mock Get-FmHerdrPaneAgentState { 'dead' }
        Get-FmHerdrAgentState -Target 'default:w1:p2' | Should -Be 'missing'
        Mock Get-FmHerdrPaneAgentState { 'no-agent' }
        Get-FmHerdrAgentState -Target 'default:w1:p2' | Should -Be 'dead'
        Mock Get-FmHerdrPaneAgentState { 'live' }
        Get-FmHerdrAgentState -Target 'default:w1:p2' | Should -Be 'alive'
        Mock Get-FmHerdrPaneAgentState { 'unknown' }
        Get-FmHerdrAgentState -Target 'default:w1:p2' | Should -Be 'unreadable'
    }

    It 'reports a malformed target as unreadable rather than guessing' {
        Get-FmHerdrAgentState -Target 'garbage' | Should -Be 'unreadable'
    }

    It 'never calls a husk live or unknown' {
        Mock Get-FmHerdrPaneAgentState { 'live' }
        Test-FmHerdrTabIsHusk -Session 'default' -PaneId 'w1:p2' | Should -BeFalse
        Mock Get-FmHerdrPaneAgentState { 'unknown' }
        Test-FmHerdrTabIsHusk -Session 'default' -PaneId 'w1:p2' | Should -BeFalse
        Mock Get-FmHerdrPaneAgentState { 'no-agent' }
        Test-FmHerdrTabIsHusk -Session 'default' -PaneId 'w1:p2' | Should -BeTrue
    }
}

Describe 'Resolve-FmHerdrWorkspace' {
    BeforeEach {
        Mock Get-FmHerdrLauncherIdentity { [pscustomobject]@{ Status = 'none'; Reason = ''; PaneId = ''; TabId = ''; WorkspaceId = '' } }
        Mock Get-FmHerdrWorkspaceLabel { 'firstmate' }
    }

    It 'adopts the single workspace carrying this home label, with no seeded tab' {
        Mock Get-FmHerdrWorkspaceIdAll { @('w4') }
        $resolved = Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj'
        $resolved.Status | Should -Be 'resolved'
        $resolved.WorkspaceId | Should -Be 'w4'
        $resolved.SeededTabId | Should -Be ''
    }

    It 'refuses when two workspaces share this home label and there is no parent pane' {
        Mock Get-FmHerdrWorkspaceIdAll { @('w4', 'w7') }
        $resolved = Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj'
        $resolved.Status | Should -Be 'refused'
        $resolved.Reason | Should -Match 'labeled .firstmate.'
    }

    It 'creates one and records the seeded default tab id when none exists' {
        Mock Get-FmHerdrWorkspaceIdAll { @() }
        Mock Invoke-FmHerdrCliJson {
            New-FakeJson @{ result = @{ workspace = @{ workspace_id = 'w9' }; tab = @{ tab_id = 't1' } } }
        }
        $resolved = Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj'
        $resolved.Status | Should -Be 'resolved'
        $resolved.WorkspaceId | Should -Be 'w9'
        $resolved.SeededTabId | Should -Be 't1'
    }

    It 'inherits the launcher workspace exactly, never a label match' {
        Mock Get-FmHerdrLauncherIdentity {
            [pscustomobject]@{ Status = 'resolved'; Reason = ''; PaneId = 'w2:p1'; TabId = 't2'; WorkspaceId = 'w2' }
        }
        Mock Get-FmHerdrWorkspaceIdAll { throw 'label search must not run when the launcher is known' }
        (Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj').WorkspaceId | Should -Be 'w2'
    }

    It 'refuses when a launcher pane is claimed but its binding is broken' {
        Mock Get-FmHerdrLauncherIdentity {
            [pscustomobject]@{ Status = 'refused'; Reason = 'cross-session parent identity'; PaneId = ''; TabId = ''; WorkspaceId = '' }
        }
        $resolved = Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj'
        $resolved.Status | Should -Be 'refused'
    }

    It 'ignores the launcher for an other-home (secondmate) placement' {
        Mock Get-FmHerdrLauncherIdentity { throw 'launcher identity must not be consulted for other-home' }
        Mock Get-FmHerdrWorkspaceIdAll { @('w5') }
        (Resolve-FmHerdrWorkspace -Session 'default' -Cwd '/proj' -Relationship 'other-home').WorkspaceId | Should -Be 'w5'
    }
}

Describe 'New-FmHerdrTask' {
    BeforeEach {
        Mock Get-FmHerdrPaneForTab { 'w1:p7' }
        Mock Remove-FmHerdrSeededDefaultTab { }
    }

    It 'creates the tab and returns its ids and target' {
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab' -and $Arguments[1] -eq 'list') { return New-FakeJson @{ result = @{ tabs = @() } } }
            New-FakeJson @{ result = @{ tab = @{ tab_id = 't5' }; root_pane = @{ pane_id = 'w1:p5' } } }
        }
        $task = New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -Confirm:$false
        $task.TabId | Should -Be 't5'
        $task.PaneId | Should -Be 'w1:p5'
        $task.Target | Should -Be 'default:w1:p5'
    }

    It 'refuses when a same-labeled tab hosts a live agent' {
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab' -and $Arguments[1] -eq 'list') {
                return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = 'fm-x' }) } }
            }
            New-FakeJson @{ result = @{ tab = @{ tab_id = 't5' }; root_pane = @{ pane_id = 'w1:p5' } } }
        }
        Mock Test-FmHerdrTabIsHusk { $false }
        { New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -Confirm:$false } |
            Should -Throw "*already exists in workspace w1*"
    }

    It 'replaces a confirmed husk, creating the replacement BEFORE closing it' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Test-FmHerdrTabIsHusk { $true }
        Mock Invoke-FmHerdrCli {
            param($Session, $Arguments)
            $script:calls.Add(($Arguments -join ' '))
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false }
        }
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab' -and $Arguments[1] -eq 'list') {
                if ($script:calls.Count -eq 0) {
                    return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = 'fm-x' }) } }
                }
                return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't5'; label = 'fm-x' }) } }
            }
            $script:calls.Add('tab create')
            New-FakeJson @{ result = @{ tab = @{ tab_id = 't5' }; root_pane = @{ pane_id = 'w1:p5' } } }
        }
        $task = New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -Confirm:$false
        $task.TabId | Should -Be 't5'
        $script:calls[0] | Should -Be 'tab create'
        $script:calls | Should -Contain 'tab close t1'
    }

    It 'refuses when the husk could not actually be removed' {
        Mock Test-FmHerdrTabIsHusk { $true }
        Mock Invoke-FmHerdrCli { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false } }
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab' -and $Arguments[1] -eq 'list') {
                return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = 'fm-x' }, @{ tab_id = 't5'; label = 'fm-x' }) } }
            }
            New-FakeJson @{ result = @{ tab = @{ tab_id = 't5' }; root_pane = @{ pane_id = 'w1:p5' } } }
        }
        { New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -Confirm:$false } |
            Should -Throw '*failed to remove preexisting herdr tab*'
    }

    It 'prunes the seeded default tab only when one was passed in' {
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab' -and $Arguments[1] -eq 'list') { return New-FakeJson @{ result = @{ tabs = @() } } }
            New-FakeJson @{ result = @{ tab = @{ tab_id = 't5' }; root_pane = @{ pane_id = 'w1:p5' } } }
        }
        $null = New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -Confirm:$false
        Should -Invoke Remove-FmHerdrSeededDefaultTab -Times 0

        $null = New-FmHerdrTask -Container 'default:w1' -Label 'fm-x' -Cwd '/wt' -SeededTabId 't1' -Confirm:$false
        Should -Invoke Remove-FmHerdrSeededDefaultTab -Times 1
    }
}

Describe 'Remove-FmHerdrSeededDefaultTab' {
    It 'refuses to close the workspace last remaining tab' {
        Mock Invoke-FmHerdrCliJson { New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = '1' }) } } }
        Mock Invoke-FmHerdrCli { throw 'must not close anything' }
        { Remove-FmHerdrSeededDefaultTab -Session 'default' -WorkspaceId 'w1' -SeededTabId 't1' -Confirm:$false } |
            Should -Not -Throw
    }

    It 'refuses when the tab was renamed away from the seeded label' {
        Mock Invoke-FmHerdrCliJson {
            New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = 'captains-work' }, @{ tab_id = 't2'; label = 'fm-x' }) } }
        }
        Mock Invoke-FmHerdrCli { throw 'must not close a renamed tab' }
        { Remove-FmHerdrSeededDefaultTab -Session 'default' -WorkspaceId 'w1' -SeededTabId 't1' -Confirm:$false } |
            Should -Not -Throw
    }

    It 'refuses when the seeded pane hosts a working agent' {
        Mock Get-FmHerdrPaneForTab { 'w1:p1' }
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab') {
                return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = '1' }, @{ tab_id = 't2'; label = 'fm-x' }) } }
            }
            New-FakeJson @{ result = @{ agent = @{ agent_status = 'working' } } }
        }
        Mock Invoke-FmHerdrCli { throw 'must not close a working pane' }
        { Remove-FmHerdrSeededDefaultTab -Session 'default' -WorkspaceId 'w1' -SeededTabId 't1' -Confirm:$false } |
            Should -Not -Throw
    }

    It 'closes the exact seeded pane when every check passes' {
        Mock Get-FmHerdrPaneForTab { 'w1:p1' }
        Mock Invoke-FmHerdrCliJson {
            param($Session, $Arguments)
            if ($Arguments[0] -eq 'tab') {
                return New-FakeJson @{ result = @{ tabs = @(@{ tab_id = 't1'; label = '1' }, @{ tab_id = 't2'; label = 'fm-x' }) } }
            }
            New-FakeJson @{ result = @{ agent = @{ agent_status = 'idle' } } }
        }
        Mock Invoke-FmHerdrCli { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false } }
        Remove-FmHerdrSeededDefaultTab -Session 'default' -WorkspaceId 'w1' -SeededTabId 't1' -Confirm:$false
        Should -Invoke Invoke-FmHerdrCli -Times 1 -ParameterFilter { $Arguments -contains 'close' -and $Arguments -contains 'w1:p1' }
    }
}

Describe 'Get-FmHerdrCapture' {
    BeforeEach { Mock Test-FmHerdrTargetReady { $true } }

    It 'always fetches at least 200 rows, because a small --lines returns nothing' {
        Mock Invoke-FmHerdrCli {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = "a`nb`nc"; StdErr = ''; Combined = ''; TimedOut = $false }
        }
        $null = Get-FmHerdrCapture -Target 'default:w1:p2' -Lines 5
        Should -Invoke Invoke-FmHerdrCli -Times 1 -ParameterFilter { $Arguments -contains '200' }
    }

    It 'trims the fetched screen to the caller bound itself' {
        $body = (1..300 | ForEach-Object { "line$_" }) -join "`n"
        Mock Invoke-FmHerdrCli {
            [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = $body; StdErr = ''; Combined = ''; TimedOut = $false }
        }.GetNewClosure()
        $capture = Get-FmHerdrCapture -Target 'default:w1:p2' -Lines 3
        ($capture -split "`n").Count | Should -Be 3
        $capture | Should -Be "line298`nline299`nline300"
    }

    It 'returns null when the read failed, never an empty screen' {
        Mock Invoke-FmHerdrCli {
            [pscustomobject]@{ Ok = $false; ExitCode = 1; StdOut = ''; StdErr = 'boom'; Combined = 'boom'; TimedOut = $false }
        }
        Get-FmHerdrCapture -Target 'default:w1:p2' -Lines 10 | Should -BeNullOrEmpty
    }
}

Describe 'Wait-FmHerdrWorking' {
    BeforeEach { Mock Start-Sleep { } }

    It 'returns busy the instant a submit-active status is seen' {
        $script:seen = 0
        Mock Get-FmHerdrAgentStatusRaw { $script:seen++; if ($script:seen -ge 2) { 'working' } else { 'idle' } }
        Wait-FmHerdrWorking -Session 'default' -PaneId 'w1:p2' -BudgetSeconds 0.6 -Polls 6 | Should -Be 'busy'
        $script:seen | Should -Be 2
    }

    It 'returns idle when the target was legible but never went busy' {
        Mock Get-FmHerdrAgentStatusRaw { 'idle' }
        Wait-FmHerdrWorking -Session 'default' -PaneId 'w1:p2' -BudgetSeconds 0.6 -Polls 3 | Should -Be 'idle'
    }

    It 'returns unknown when every poll failed to read the target' {
        Mock Get-FmHerdrAgentStatusRaw { '' }
        Wait-FmHerdrWorking -Session 'default' -PaneId 'w1:p2' -BudgetSeconds 0.6 -Polls 3 | Should -Be 'unknown'
    }
}

Describe 'Send-FmHerdrTextSubmit' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Test-FmHerdrTargetReady { $true }
    }

    It 'types once and confirms from native agent state' {
        Mock Send-FmHerdrLiteral { $true }
        Mock Send-FmHerdrKey { $true }
        Mock Get-FmHerdrAgentStatusRaw { 'idle' }
        Mock Wait-FmHerdrWorking { 'busy' }
        Send-FmHerdrTextSubmit -Target 'default:w1:p2' -Text 'hello' | Should -Be 'empty'
        Should -Invoke Send-FmHerdrLiteral -Times 1
        Should -Invoke Send-FmHerdrKey -Times 1
    }

    It 'retries Enter only, and never retypes the text' {
        Mock Send-FmHerdrLiteral { $true }
        Mock Send-FmHerdrKey { $true }
        Mock Get-FmHerdrAgentStatusRaw { 'idle' }
        Mock Wait-FmHerdrWorking { 'idle' }
        Send-FmHerdrTextSubmit -Target 'default:w1:p2' -Text 'hello' -Retries 3 | Should -Be 'pending'
        Should -Invoke Send-FmHerdrLiteral -Times 1
        Should -Invoke Send-FmHerdrKey -Times 3
    }

    It 'reports send-failed when the text itself did not go out' {
        Mock Send-FmHerdrLiteral { $false }
        Mock Send-FmHerdrKey { throw 'Enter must not be sent after a failed type' }
        Send-FmHerdrTextSubmit -Target 'default:w1:p2' -Text 'hello' | Should -Be 'send-failed'
    }

    It 'reports unknown when the target cannot be read at all' {
        Mock Send-FmHerdrLiteral { $true }
        Mock Send-FmHerdrKey { $true }
        Mock Get-FmHerdrAgentStatusRaw { 'idle' }
        Mock Wait-FmHerdrWorking { 'unknown' }
        Send-FmHerdrTextSubmit -Target 'default:w1:p2' -Text 'hello' | Should -Be 'unknown'
    }

    It 'falls back to the shared composer classifier when the baseline is not idle' {
        Mock Send-FmHerdrLiteral { $true }
        Mock Send-FmHerdrKey { $true }
        Mock Get-FmHerdrAgentStatusRaw { 'working' }
        Mock Wait-FmHerdrWorking { throw 'native confirmation is meaningless when already working' }
        Mock Get-FmHerdrComposerState { 'empty' }
        Send-FmHerdrTextSubmit -Target 'default:w1:p2' -Text 'hello' | Should -Be 'empty'
    }

    It 'reports unknown for an unreadable target shape without sending anything' {
        Mock Send-FmHerdrLiteral { throw 'must not send to a malformed target' }
        Send-FmHerdrTextSubmit -Target 'garbage' -Text 'hello' | Should -Be 'unknown'
    }
}

Describe 'Get-FmHerdrComposerState' {
    It 'stays unknown when no fleet-wide classifier is loaded' {
        # The shape catalogue is explicitly one fleet-wide owner; this adapter
        # must not grow a private copy, and unknown is the fail-safe verdict.
        Get-FmHerdrComposerState -Target 'default:w1:p2' | Should -Be 'unknown'
    }
}

Describe 'Remove-FmHerdrPane' {
    BeforeEach { Mock Test-FmHerdrTargetReady { $true } }

    It 'succeeds only when a structured presence read proves the pane gone' {
        Mock Invoke-FmHerdrCli { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false } }
        Mock Get-FmHerdrPanePresenceState { 'dead' }
        Remove-FmHerdrPane -Target 'default:w1:p2' -Confirm:$false | Should -BeTrue
    }

    It 'reports failure when the pane is still present after the close' {
        Mock Invoke-FmHerdrCli { [pscustomobject]@{ Ok = $true; ExitCode = 0; StdOut = ''; StdErr = ''; Combined = ''; TimedOut = $false } }
        Mock Get-FmHerdrPanePresenceState { 'present' }
        Remove-FmHerdrPane -Target 'default:w1:p2' -Confirm:$false | Should -BeFalse
    }

    It 'never treats an unknown presence as proof the endpoint is gone' {
        Mock Get-FmHerdrPanePresenceState { 'unknown' }
        Test-FmHerdrEndpointGone -Target 'default:w1:p2' | Should -BeFalse
        Test-FmHerdrEndpointGone -Target 'garbage' | Should -BeFalse
    }
}

Describe 'Get-FmHerdrLiveTask' {
    It 'lists task tabs by label in this home workspace only' {
        Mock Get-FmHerdrWorkspaceId { 'w1' }
        Mock Get-FmHerdrPaneForTab { 'w1:p3' }
        Mock Invoke-FmHerdrCliJson {
            New-FakeJson @{ result = @{ tabs = @(
                @{ tab_id = 't1'; label = 'fm-alpha' },
                @{ tab_id = 't2'; label = 'captains-scratch' }
            ) } }
        }
        $live = @(Get-FmHerdrLiveTask -Session 'default')
        $live.Count | Should -Be 1
        $live[0].Label | Should -Be 'fm-alpha'
        $live[0].Target | Should -Be 'default:w1:p3'
    }

    It 'lists nothing when this home has no workspace yet' {
        Mock Get-FmHerdrWorkspaceId { '' }
        @(Get-FmHerdrLiveTask -Session 'default').Count | Should -Be 0
    }
}

Describe 'task metadata' {
    BeforeEach {
        $script:meta = Join-Path $TestDrive 'alpha.meta'
        Set-Content -LiteralPath $script:meta -Value @(
            'window=default:w1:p2'
            'endpoint_task_id=alpha'
            'worktree=/wt/alpha'
            'project=/proj'
            'harness=claude'
            'kind=ship'
            'backend=herdr'
            'herdr_session=default'
            'herdr_workspace_id=w1'
            'herdr_tab_id=t1'
            'herdr_pane_id=w1:p2'
        )
    }

    It 'reads the last value of a repeated key' {
        Add-Content -LiteralPath $script:meta -Value 'harness=codex'
        Get-FmMetaValue -Path $script:meta -Key 'harness' | Should -Be 'codex'
    }

    It 'refuses an ambiguous key for endpoint identity' {
        Get-FmMetaExactValue -Path $script:meta -Key 'window' | Should -Be 'default:w1:p2'
        Add-Content -LiteralPath $script:meta -Value 'window=other:w9:p9'
        Get-FmMetaExactValue -Path $script:meta -Key 'window' | Should -BeNullOrEmpty
    }

    It 'defaults an absent backend to tmux, the compatibility contract' {
        $bare = Join-Path $TestDrive 'bare.meta'
        Set-Content -LiteralPath $bare -Value @('window=session:fm-bare')
        Get-FmMetaBackend -Path $bare | Should -Be 'tmux'
    }

    It 'validates a well-formed herdr endpoint' {
        $endpoint = Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'alpha'
        $endpoint.Valid | Should -BeTrue
        $endpoint.Backend | Should -Be 'herdr'
        $endpoint.Target | Should -Be 'default:w1:p2'
    }

    It 'refuses metadata that belongs to another task' {
        (Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'beta').Reason |
            Should -Match 'belongs to task alpha, not beta'
    }

    It 'refuses a herdr endpoint whose window and pane fields disagree' {
        (Get-Content -LiteralPath $script:meta) -replace '^herdr_pane_id=.*', 'herdr_pane_id=w9:p9' |
            Set-Content -LiteralPath $script:meta
        (Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'alpha').Reason |
            Should -Match 'malformed or inconsistent'
    }

    It 'refuses a herdr record with no exact task binding' {
        (Get-Content -LiteralPath $script:meta) -replace '^endpoint_task_id=.*', 'endpoint_task_id=' |
            Set-Content -LiteralPath $script:meta
        (Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'alpha').Reason |
            Should -Match 'lacks an exact task binding'
    }

    It 'refuses a backend this port cannot drive rather than validating it blind' {
        (Get-Content -LiteralPath $script:meta) -replace '^backend=.*', 'backend=zellij' |
            Set-Content -LiteralPath $script:meta
        (Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'alpha').Reason |
            Should -Match 'does not implement'
    }

    It 'refuses an endpoint field carrying a stray control character' {
        (Get-Content -LiteralPath $script:meta) -replace '^project=.*', "project=/proj`tinjected" |
            Set-Content -LiteralPath $script:meta
        (Test-FmTaskEndpoint -MetaPath $script:meta -TaskId 'alpha').Reason |
            Should -Match 'malformed endpoint metadata'
    }

    It 'refuses a missing record without touching task state' {
        (Test-FmTaskEndpoint -MetaPath (Join-Path $TestDrive 'nope.meta') -TaskId 'alpha').Reason |
            Should -Match 'preserving task state'
    }
}

Describe 'Resolve-FmTaskSelector' {
    BeforeEach {
        $script:stateDir = Join-Path $TestDrive 'state'
        New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:stateDir 'alpha.meta') -Value @(
            'window=default:w1:p2'
            'harness=claude'
            'backend=herdr'
        )
    }

    It 'resolves an exact task id through this home metadata' {
        $resolved = Resolve-FmTaskSelector -Selector 'alpha' -StateDir $script:stateDir
        $resolved.Resolved | Should -BeTrue
        $resolved.Target | Should -Be 'default:w1:p2'
        $resolved.ExpectedLabel | Should -Be 'fm-alpha'
        $resolved.Harness | Should -Be 'claude'
    }

    It 'resolves the legacy fm-prefixed task label' {
        (Resolve-FmTaskSelector -Selector 'fm-alpha' -StateDir $script:stateDir).Target | Should -Be 'default:w1:p2'
    }

    It 'refuses an unknown fm-prefixed label loudly instead of searching' {
        $resolved = Resolve-FmTaskSelector -Selector 'fm-ghost' -StateDir $script:stateDir
        $resolved.Resolved | Should -BeFalse
        $resolved.Reason | Should -Match 'no metadata for fm-ghost'
    }

    It 'refuses an unresolvable bare selector' {
        (Resolve-FmTaskSelector -Selector 'ghost' -StateDir $script:stateDir).Resolved | Should -BeFalse
    }

    It 'accepts an explicit backend target only when its endpoint verifies' {
        Mock Test-FmHerdrTargetExists { $true }
        (Resolve-FmTaskSelector -Selector 'other:w4:p1' -StateDir $script:stateDir).Target | Should -Be 'other:w4:p1'
        Mock Test-FmHerdrTargetExists { $false }
        (Resolve-FmTaskSelector -Selector 'other:w4:p1' -StateDir $script:stateDir).Resolved | Should -BeFalse
    }
}

Describe 'control-plane capability tables' {
    It 'maps a recorded harness onto its verified adapter family' {
        Get-FmControlHarnessFamily -RecordedHarness 'claude' | Should -Be 'claude'
        Get-FmControlHarnessFamily -RecordedHarness 'claude-custom' | Should -Be 'claude'
        Get-FmControlHarnessFamily -RecordedHarness 'pi' | Should -Be 'pi'
        Get-FmControlHarnessFamily -RecordedHarness 'pi-signed' | Should -Be 'pi-signed'
        Get-FmControlHarnessFamily -RecordedHarness 'nonsense' | Should -Be ''
    }

    It 'knows grok interrupts on Ctrl+C and opencode needs a double Escape' {
        Get-FmControlInterruptKey -Harness 'grok' | Should -Be 'C-c'
        Get-FmControlInterruptKey -Harness 'claude' | Should -Be 'Escape'
        Get-FmControlInterruptRepeat -Harness 'opencode' | Should -Be 2
        Get-FmControlInterruptRepeat -Harness 'claude' | Should -Be 1
    }

    It 'knows muse alone needs its composer cleared after an interrupt' {
        Get-FmControlInterruptClearKey -Harness 'muse' | Should -Be 'C-u'
        Get-FmControlInterruptClearKey -Harness 'claude' | Should -Be ''
    }

    It 'knows which exit command each adapter takes' {
        Get-FmControlExitCommand -Harness 'claude' | Should -Be '/exit'
        Get-FmControlExitCommand -Harness 'codex' | Should -Be '/quit'
        Get-FmControlExitCommand -Harness 'pi-signed' | Should -Be '/quit'
        Get-FmControlExitCommand -Harness 'nonsense' | Should -Be ''
    }

    It 'knows orca can deliver neither Escape nor Ctrl+U' {
        Test-FmControlBackendSupportsKey -Backend 'herdr' -Key 'Escape' | Should -BeTrue
        Test-FmControlBackendSupportsKey -Backend 'orca' -Key 'Escape' | Should -BeFalse
        Test-FmControlBackendSupportsKey -Backend 'orca' -Key 'Enter' | Should -BeTrue
    }

    It 'only trusts a stop postcondition on a backend with a state classifier' {
        Test-FmControlBackendStateVerified -Backend 'herdr' | Should -BeTrue
        Test-FmControlBackendStateVerified -Backend 'tmux' | Should -BeTrue
        Test-FmControlBackendStateVerified -Backend 'zellij' | Should -BeFalse
    }
}

Describe 'Send-FmControlInterrupt' {
    It 'delivers the interrupt key the verified number of times' {
        Mock Send-FmHerdrKey { $true }
        Mock Start-Sleep { }
        Send-FmControlInterrupt -Backend 'herdr' -Target 'default:w1:p2' -Harness 'opencode' | Should -Be 'unconfirmed'
        Should -Invoke Send-FmHerdrKey -Times 2
    }

    It 'follows muse Escape with the composer clear' {
        Mock Send-FmHerdrKey { $true }
        Mock Start-Sleep { }
        $null = Send-FmControlInterrupt -Backend 'herdr' -Target 'default:w1:p2' -Harness 'muse'
        Should -Invoke Send-FmHerdrKey -Times 1 -ParameterFilter { $Key -eq 'C-u' }
    }

    It 'refuses before sending when the backend cannot deliver the key' {
        Mock Send-FmHerdrKey { throw 'must not send' }
        { Send-FmControlInterrupt -Backend 'orca' -Target 'default:w1:p2' -Harness 'claude' } |
            Should -Throw '*cannot deliver*'
    }

    It 'refuses an unverified harness rather than guessing a key' {
        { Send-FmControlInterrupt -Backend 'herdr' -Target 'default:w1:p2' -Harness 'nonsense' } |
            Should -Throw '*no verified interrupt mechanics*'
    }
}

Describe 'LF file contracts' {
    It 'writes LF, no BOM, so a Linux firstmate reads the same bytes' {
        $path = Join-Path $TestDrive 'contract.txt'
        Write-FmTextFileLf -Path $path -Text "a`r`nb`n"
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes | Should -Not -Contain 13
        $bytes[0] | Should -Be 97
    }

    It 'appends one status event per line, flattening embedded newlines' {
        $stateDir = Join-Path $TestDrive 'statuslines'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Add-FmStatusEvent -StateDir $stateDir -TaskId 'alpha' -State 'working' -Note "setup done"
        Add-FmStatusEvent -StateDir $stateDir -TaskId 'alpha' -State 'blocked' -Note "two`nlines"
        $raw = [System.IO.File]::ReadAllText((Join-Path $stateDir 'alpha.status'))
        $raw | Should -Be "working: setup done`nblocked: two lines`n"
    }
}
