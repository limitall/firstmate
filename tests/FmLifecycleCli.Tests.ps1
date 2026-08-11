#requires -Version 7.0
# Entry-point tests: the bin/fm-*.ps1 scripts really run, parse their documented
# flags, and exit with the codes a supervisor branches on.
#
# The scripts import the module manifest, which the module's foundation owns. So
# the suite runs them from a copy of the repo, adding a stand-in manifest only
# when the real one is not there yet; once it lands, the real one is used.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')

    $script:Tree = Join-Path ([System.IO.Path]::GetTempPath()) ('fmwin-cli-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12))
    $repoRoot = Get-FmLifecycleRepoRoot
    [void](New-Item -ItemType Directory -Path $script:Tree -Force)
    Copy-Item -Path (Join-Path $repoRoot 'module') -Destination $script:Tree -Recurse -Force
    Copy-Item -Path (Join-Path $repoRoot 'bin') -Destination $script:Tree -Recurse -Force

    $moduleDir = Join-Path $script:Tree 'module/Firstmate'
    $manifest = Join-Path $moduleDir 'Firstmate.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        $loader = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($sub in @('Private', 'Public')) {
    $dir = Join-Path $PSScriptRoot $sub
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name)) { . $file.FullName }
    }
}
Export-ModuleMember -Function 'Get-Fm*', 'New-Fm*', 'Invoke-Fm*', 'Test-Fm*', 'Convert-Fm*'
'@
        [System.IO.File]::WriteAllText((Join-Path $moduleDir 'Firstmate.psm1'), $loader)
        [System.IO.File]::WriteAllText($manifest, "@{ ModuleVersion = '0.0.0'; RootModule = 'Firstmate.psm1'; FunctionsToExport = '*'; PowerShellVersion = '7.0' }`n")
        $script:UsedStandIn = $true
    }

    $script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function Invoke-FmCli {
        param([Parameter(Mandatory)][string]$Script, [string[]]$CliArgs = @())
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:Pwsh
        foreach ($a in (@('-NoProfile', '-File', (Join-Path $script:Tree "bin/$Script")) + $CliArgs)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_ROOT_OVERRIDE')) {
            $value = [System.Environment]::GetEnvironmentVariable($name)
            if ($value) { $psi.Environment[$name] = $value }
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
    }
}

AfterAll {
    if ($script:Tree -and (Test-Path -LiteralPath $script:Tree)) {
        Remove-Item -LiteralPath $script:Tree -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'bin/fm-brief.ps1' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'scaffolds a ship brief and exits 0' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', 'acme/widget', '--mode', 'direct-PR')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match 'scaffolded: .*brief\.md \(ship, mode=direct-PR; replace \{TASK\}\)'
        $text = [System.IO.File]::ReadAllText((Join-Path $script:TestHome.Data 't1/brief.md'))
        $text | Should -Match 'Delivery contract: mode=direct-PR'
        $text | Should -Match '\*\*Verify isolation before anything else\.\*\*'
    }

    It 'refuses a ship brief with no delivery mode' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', 'acme/widget')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'ship briefs require --mode'
    }

    It 'refuses --mode on a scout' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', 'acme/widget', '--scout', '--mode', 'direct-PR')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match '--mode applies only to ship briefs'
    }

    It 'refuses --yolo loudly rather than dropping it' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', 'acme/widget', '--mode', 'direct-PR', '--yolo')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match '--yolo is not a brief input'
    }

    It 'refuses --herdr-lab on a secondmate charter' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', '--secondmate', 'proj-a', '--herdr-lab')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match '--herdr-lab applies only to crewmate'
    }

    It 'scaffolds a secondmate charter from a project list' {
        $result = Invoke-FmCli -Script 'fm-brief.ps1' -CliArgs @('t1', '--secondmate', 'proj-a', 'proj-b')
        $result.ExitCode | Should -Be 0
        $text = [System.IO.File]::ReadAllText((Join-Path $script:TestHome.Data 't1/brief.md'))
        $text | Should -Match '(?m)^- proj-a$'
        $text | Should -Match '(?m)^- proj-b$'
    }
}

Describe 'bin/fm-teardown.ps1' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'exits 2 on an invalid request' {
        (Invoke-FmCli -Script 'fm-teardown.ps1').ExitCode | Should -Be 2
        (Invoke-FmCli -Script 'fm-teardown.ps1' -CliArgs @('t1', '--wat')).ExitCode | Should -Be 2
    }

    It 'exits 1 and preserves the task when work has not landed' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            window   = 'fleet:fm-t1'
            backend  = 'herdr'
        } | Out-Null
        $result = Invoke-FmCli -Script 'fm-teardown.ps1' -CliArgs @('t1')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'REFUSED: worktree .* has work not on any remote and not landed\.'
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
    }

    It 'exits 2 on a bare --force, which discards work without naming an authority' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            backend  = 'herdr'
        } | Out-Null
        $result = Invoke-FmCli -Script 'fm-teardown.ps1' -CliArgs @('t1', '--force')
        $result.ExitCode | Should -Be 2
        $result.StdErr | Should -Match 'requires --approved-by'
        Test-Path -LiteralPath (Join-Path $script:TestHome.State 't1.meta') | Should -BeTrue
    }

    It 'accepts --force WITH an explicit discard authority' {
        # No `window`: with no endpoint recorded there is no pane to confirm
        # gone, which is the shape a task has once its endpoint was cleared.
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = (Join-Path $script:TestHome.Path 'already-returned')
            project  = $script:Repo.Project
            backend  = 'herdr'
        } | Out-Null
        $result = Invoke-FmCli -Script 'fm-teardown.ps1' -CliArgs @('t1', '--force', '--approved-by', 'captain')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match 'teardown t1 complete'
    }

    It 'refuses a backend this port does not drive' {
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            backend  = 'tmux'
        } | Out-Null
        $result = Invoke-FmCli -Script 'fm-teardown.ps1' -CliArgs @('t1')
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'herdr session provider only'
    }
}

Describe 'bin/fm-merge-local.ps1' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $script:Repo = New-FmTestProject -Root $script:TestHome.Path -Id 't1'
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'merges an approved local-only branch' {
        New-FmTestCommit -RepoPath $script:Repo.Worktree
        New-FmTestMeta -TestHome $script:TestHome -Id 't1' -Fields @{
            worktree = $script:Repo.Worktree
            project  = $script:Repo.Project
            mode     = 'local-only'
        } | Out-Null
        $result = Invoke-FmCli -Script 'fm-merge-local.ps1' -CliArgs @('t1')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match 'merged fm/t1 into local main'
    }

    It 'exits 1 without a task id' {
        (Invoke-FmCli -Script 'fm-merge-local.ps1').ExitCode | Should -Be 1
    }
}

Describe 'bin/fm-crew-state.ps1' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'prints one parseable state line and exits 0' {
        $result = Invoke-FmCli -Script 'fm-crew-state.ps1' -CliArgs @('t1')
        $result.ExitCode | Should -Be 0
        $result.StdOut.Trim() | Should -Be 'state: unknown · source: none · no metadata for t1'
    }

    It 'exits 2 on a usage error' {
        (Invoke-FmCli -Script 'fm-crew-state.ps1').ExitCode | Should -Be 2
    }
}
