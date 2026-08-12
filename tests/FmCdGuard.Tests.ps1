#requires -Version 7.0
# Pester tests for the cd guard: the shell classifier in
# Private/FmShellClassify.ps1, the policy in Public/FmCdGuard.ps1, and the scope
# in Private/FmCdGuard.ps1.
#
# These are NOT documentation-only. Everything here is ordinary in-process
# classification and file/git inspection, so it is proven on whichever host runs
# the suite. What stays Windows-unverified is only what Claude Code DOES with the
# resulting deny, which docs/claude-hooks-windows.md owns.
#
# The verdicts asserted below were differentially compared, case by case, against
# the Linux reference implementation - bin/fm-cd-command-policy.mjs run under
# node - over 119 commands, with zero disagreements. See
# docs/cd-guard-windows.md.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp checkouts. -WhatIf on a fixture would leave the test asserting against a checkout that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # Pester containers share one process, so an FM_* override left set by
    # another file decides this file's behaviour. Save every key this file
    # touches and restore it in AfterAll.
    $script:SavedEnvironment = @{}
    foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE')) {
        $script:SavedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Set-Item -Path "env:$name" -Value $null
    }

    function Invoke-Git {
        param([string]$Directory, [string[]]$GitArguments)
        & git -C $Directory @GitArguments 2>&1 | Out-Null
    }

    # A checkout shaped like a real PRIMARY firstmate checkout: AGENTS.md, bin/,
    # and a plain (non-worktree) git repository where git-dir equals
    # git-common-dir. This is the only shape the guard fires in.
    function New-PrimaryCheckout {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), "fixture`n")
        Invoke-Git -Directory $root -GitArguments @('init', '--initial-branch=main', '.')
        Invoke-Git -Directory $root -GitArguments @('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit',
            '--allow-empty', '-m', 'root')
        return $root
    }

    # The shape bin/fm-spawn.ps1 hands every crewmate and scout: a LINKED git
    # worktree, where git-dir and git-common-dir differ.
    $script:Worktrees = [System.Collections.Generic.List[object]]::new()
    function New-LinkedWorktree {
        param([string]$From)
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Invoke-Git -Directory $From -GitArguments @('worktree', 'add', '--detach', $path)
        [System.IO.File]::WriteAllText((Join-Path $path 'AGENTS.md'), "fixture`n")
        New-Item -ItemType Directory -Path (Join-Path $path 'bin') -Force | Out-Null
        $script:Worktrees.Add(@{ From = $From; Path = $path })
        return $path
    }

    $script:Primary = New-PrimaryCheckout

    function Get-Verdict {
        param([string]$Command, [string]$Root = $script:Primary)
        Test-FmCdCommandPolicy -Command $Command -Root $Root
    }
}

AfterAll {
    # Tear the git fixtures down explicitly rather than leaving them to Pester's
    # TestDrive cleanup. On Windows every file under .git/objects is created
    # READ-ONLY, and a linked worktree also leaves a registration in the parent
    # repository, so the automatic cleanup can fail - and a container that fails
    # to tear down reports Result=Failed while every test in it PASSED. Reading
    # only the passed/failed counts hides that completely; it was caught by
    # running these tests from inside a real Claude session, which surfaces
    # $r.Result rather than the counts.
    foreach ($worktree in @($script:Worktrees)) {
        & git -C $worktree.From worktree remove --force $worktree.Path 2>&1 | Out-Null
        & git -C $worktree.From worktree prune 2>&1 | Out-Null
    }
    Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.IsReadOnly } |
        ForEach-Object { try { $_.IsReadOnly = $false } catch { Write-Debug "could not clear read-only on $($_.FullName): $_" } }

    foreach ($name in $script:SavedEnvironment.Keys) {
        Set-Item -Path "env:$name" -Value $script:SavedEnvironment[$name]
    }
}

Describe 'Test-FmCdCommandPolicy denies a persistent top-level cwd change' {
    # This is THE case the guard exists for, and the one the Linux guard denies:
    # a bare cd into a project clone in the primary shell.
    It 'denies <Command>' -ForEach @(
        @{ Command = 'cd projects/acme' }
        @{ Command = 'cd projects/acme && git status' }
        @{ Command = 'git status && cd projects/acme' }
        @{ Command = 'cd /tmp; echo done' }
        @{ Command = 'cd projects/acme || true' }
        @{ Command = 'pushd projects/acme' }
        @{ Command = 'popd' }
        @{ Command = 'cd' }
        @{ Command = 'cd -' }
        @{ Command = 'FOO=bar cd projects/acme' }
        # Quoting must not hide the builtin from the classifier.
        @{ Command = '"cd" projects/acme' }
        @{ Command = "'cd' projects/acme" }
        @{ Command = 'c"d" projects/acme' }
        @{ Command = "`$'cd' projects/acme" }
        @{ Command = "`$'\x63\x64' projects/acme" }
        # A line continuation splices the word back together.
        @{ Command = "c\`nd projects/acme" }
        # Both of these run the builtin in the CALLING shell.
        @{ Command = 'command cd projects/acme' }
        @{ Command = 'builtin cd projects/acme' }
        @{ Command = 'cd $(pwd)' }
        @{ Command = 'cd "$HOME"' }
    ) {
        $verdict = Get-Verdict -Command $Command
        $verdict.Deny | Should -BeTrue -Because "'$Command' moves the primary shell"
        $verdict.Code | Should -Be 'persistent-cd'
        $verdict.Reason | Should -BeLike '*persistent top-level directory change*'
    }
}

Describe 'Test-FmCdCommandPolicy allows everything that cannot persist' {
    It 'allows <Command>' -ForEach @(
        # An ordinary command, which is the overwhelming majority of tool calls
        # and the case a broken guard turns into an outage.
        @{ Command = 'git status' }
        @{ Command = 'ls -la' }
        @{ Command = 'pwsh -NoProfile -Command "Invoke-Pester -Path ./tests"' }
        @{ Command = 'git -C projects/acme status' }
        # The documented ways to reach a directory without moving the shell.
        @{ Command = '(cd projects/acme && git status)' }
        @{ Command = '{ cd projects/acme; }' }
        @{ Command = 'cd projects/acme &' }
        @{ Command = 'cd projects/acme | cat' }
        @{ Command = 'echo hi | cd projects/acme' }
        # cd inside a substitution runs in a subshell.
        @{ Command = '$(cd projects/acme)' }
        @{ Command = 'echo $(cd x && pwd)' }
        @{ Command = 'echo `cd projects/acme`' }
        # Quoted DATA that merely mentions cd is not a command.
        @{ Command = 'echo "cd projects/acme"' }
        @{ Command = "echo 'cd projects/acme'" }
        @{ Command = 'git commit -m "cd into the dir"' }
        @{ Command = "grep -r 'cd ' ." }
        # Fork/exec wrappers: the builtin never reaches the parent shell.
        @{ Command = 'env cd projects/acme' }
        @{ Command = 'sudo cd projects/acme' }
        @{ Command = 'nohup cd projects/acme' }
        @{ Command = 'timeout 5 cd projects/acme' }
        @{ Command = 'exec cd projects/acme' }
        @{ Command = 'sudo -u root cd projects/acme' }
        @{ Command = 'timeout --kill-after=5 10 cd projects/acme' }
        # The external utility, not the builtin.
        @{ Command = '/usr/bin/command cd projects/acme' }
        # Asking where cd is, not running it.
        @{ Command = 'command -v cd' }
        @{ Command = 'command -V cd' }
        # Not the cd builtin at all. Shell command names are case-SENSITIVE.
        @{ Command = 'CD projects/acme' }
        @{ Command = 'cdx' }
        @{ Command = 'xcd' }
        @{ Command = './cd x' }
        @{ Command = 'npm run cd' }
        # A comment, and a redirection target that happens to be named cd.
        @{ Command = '# cd projects/acme' }
        @{ Command = 'echo a > cd' }
        # Nothing to judge.
        @{ Command = '' }
        @{ Command = '   ' }
    ) {
        (Get-Verdict -Command $Command).Deny | Should -BeFalse -Because "'$Command' cannot move the primary shell"
    }
}

Describe 'Test-FmCdCommandPolicy and heredocs' {
    # A heredoc BODY is data. Reading it as commands is a false DENY, which is
    # the worse of the two failures: it stops work that was never unsafe.
    It 'does not read a heredoc body as a command' {
        (Get-Verdict -Command "cat <<EOF`ncd projects/acme`nEOF").Deny | Should -BeFalse
        (Get-Verdict -Command "cat <<'EOF'`ncd projects/acme`nEOF").Deny | Should -BeFalse
        (Get-Verdict -Command "cat <<-EOF`n`tcd projects/acme`n`tEOF").Deny | Should -BeFalse
    }

    It 'still denies a cd that follows a closed heredoc' {
        (Get-Verdict -Command "cat <<EOF`nplain text`nEOF`ncd projects/acme").Deny | Should -BeTrue
    }
}

Describe 'Test-FmCdCommandPolicy fails open on syntax it cannot tokenize' {
    # The threat model is agent MISTAKES, and an accidental bare `cd x` always
    # tokenizes. Unparseable input is allowed rather than guessed at, which is
    # what the bash original does and says.
    It 'allows <Command>, which does not lex' -ForEach @(
        @{ Command = "echo unterminated 'quote" }
        @{ Command = 'echo "unterminated' }
        @{ Command = 'echo $(unterminated' }
        @{ Command = "cat <<EOF`nnever closed" }
    ) {
        (Get-Verdict -Command $Command).Deny | Should -BeFalse
    }
}

Describe 'Test-FmCdGuardScope' {
    It 'fires in a plain primary checkout' {
        Test-FmCdGuardScope -Root $script:Primary | Should -BeTrue
    }

    It 'is INERT in a linked worktree, which is every crewmate and scout task worktree' {
        # A worker in a task worktree cds freely. Denying there would break the
        # very sessions firstmate dispatches.
        $worktree = New-LinkedWorktree -From $script:Primary
        Test-FmCdGuardScope -Root $worktree | Should -BeFalse
        (Get-Verdict -Command 'cd projects/acme' -Root $worktree).Deny | Should -BeFalse
        # And it is a genuine linked worktree, not merely a directory the scope
        # happened to reject: git-dir and git-common-dir must actually differ.
        $gitDir = (& git -C $worktree rev-parse --git-dir)
        $common = (& git -C $worktree rev-parse --git-common-dir)
        $gitDir | Should -Not -Be $common
    }

    It 'is INERT in a directory with no AGENTS.md' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        Invoke-Git -Directory $root -GitArguments @('init', '.')
        Test-FmCdGuardScope -Root $root | Should -BeFalse
        (Get-Verdict -Command 'cd projects/acme' -Root $root).Deny | Should -BeFalse
    }

    It 'is INERT in a directory with no bin/' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), "fixture`n")
        Invoke-Git -Directory $root -GitArguments @('init', '.')
        Test-FmCdGuardScope -Root $root | Should -BeFalse
    }

    It 'is INERT outside a git repository' {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), "fixture`n")
        Test-FmCdGuardScope -Root $root | Should -BeFalse
    }

    It 'is INERT for an empty root rather than throwing' {
        Test-FmCdGuardScope -Root '' | Should -BeFalse
        Test-FmCdGuardScope -Root $null | Should -BeFalse
    }
}

Describe 'The shell classifier' {
    It 'consumes a subshell group whole instead of lexing its contents at top level' {
        $lexed = ConvertTo-FmShellToken -Command '(cd x && y)'
        $lexed.Error | Should -Be ''
        @($lexed.Tokens).Count | Should -Be 1
        $lexed.Tokens[0].Type | Should -Be 'group'
        $lexed.Tokens[0].Kind | Should -Be 'subshell'
    }

    It 'reports an error rather than a verdict for input it cannot tokenize' {
        (ConvertTo-FmShellToken -Command "echo 'unclosed").Error | Should -Not -Be ''
        (ConvertTo-FmShellToken -Command 'echo "unclosed').Error | Should -Not -Be ''
        (ConvertTo-FmShellToken -Command 'echo $(unclosed').Error | Should -Not -Be ''
    }

    It 'decodes ANSI-C quoting case-sensitively, so \e and \E are both escape' {
        # A PowerShell hash literal silently folds these two keys into one; the
        # classifier must not.
        (ConvertFrom-FmShellAnsiCQuote -Source "`$'\e'" -Start 0).Value | Should -Be "`e"
        (ConvertFrom-FmShellAnsiCQuote -Source "`$'\E'" -Start 0).Value | Should -Be "`e"
        (ConvertFrom-FmShellAnsiCQuote -Source "`$'\x63\x64'" -Start 0).Value | Should -Be 'cd'
    }

    It 'strips a redirection target so it is never read as a command word' {
        $lexed = ConvertTo-FmShellToken -Command '> cd echo hi'
        $position = Get-FmShellCommandPosition -Token ([hashtable[]]@($lexed.Tokens))
        [string]$position.Command.Value | Should -Be 'echo'
    }

    It 'steps over wrappers to reach the executed word' {
        $lexed = ConvertTo-FmShellToken -Command 'sudo -u root timeout 5 git status'
        $position = Get-FmShellCommandPosition -Token ([hashtable[]]@($lexed.Tokens))
        [string]$position.Command.Value | Should -Be 'git'
        $position.Wrappers | Should -Contain 'sudo'
        $position.Wrappers | Should -Contain 'timeout'
    }

    It 'records the separator that follows each node' {
        $lexed = ConvertTo-FmShellToken -Command 'a && b | c'
        $program = Split-FmShellProgram -Token ([hashtable[]]@($lexed.Tokens))
        @($program.Nodes).Count | Should -Be 3
        @($program.Separators) | Should -Be @('&&', '|')
    }
}
