@{
    # Self-test case list for tools/fm-ps-diff.ps1. This file doubles as the
    # worked example a conversion author copies: a real conversion ships the
    # same shape next to the script it verifies (e.g. tools/cases/fm-pr-lib.psd1).
    #
    #   pwsh -NoProfile -File tools/fm-ps-diff.ps1 -CaseFile tools/selftest/cases.psd1
    #   pwsh -NoProfile -File tools/fm-ps-diff.ps1 -CaseFile tools/selftest/cases.psd1 -Case echo-args-match -ShowRules
    #
    # The ExpectMismatch cases below are the harness's own negative proof.
    # NEVER put an ExpectMismatch case in a conversion case list: it asserts
    # that the twins DIFFER, which is the opposite of what a conversion claims.

    Defaults = @{
        FixtureTemplate = 'tools/selftest/fixtures/home'
        Env             = @{ FM_HOME = '<ROOT>' }
        Stdin           = "line one`nline two`n"
        TimeoutSec      = 120
    }

    Cases = @(
        @{
            Name        = 'echo-args-match'
            Description = 'correct twin: every dimension must agree'
            Shape       = 'Script'
            Bash        = 'tools/selftest/echo-args.sh'
            Pwsh        = 'tools/selftest/echo-args.ps1'
            Args        = @('0', 'alpha', 'beta gamma')
        }
        @{
            Name        = 'echo-args-distinct-exit'
            Description = 'correct twin preserves a distinct non-zero exit (contract 1)'
            Shape       = 'Script'
            Bash        = 'tools/selftest/echo-args.sh'
            Pwsh        = 'tools/selftest/echo-args.ps1'
            Args        = @('8', 'solo')
        }
        @{
            Name           = 'catch-exit-code'
            Description    = 'NEGATIVE: twin is off by one on the exit code'
            Shape          = 'Script'
            Bash           = 'tools/selftest/echo-args.sh'
            Pwsh           = 'tools/selftest/echo-args-bad-exit.ps1'
            Args           = @('2', 'alpha')
            ExpectMismatch = @{
                Reason     = 'proves the harness fails on an exit-code divergence'
                Dimensions = @('exit')
            }
        }
        @{
            Name           = 'catch-stdout'
            Description    = 'NEGATIVE: twin joins argv with the wrong separator on stdout'
            Shape          = 'Script'
            Bash           = 'tools/selftest/echo-args.sh'
            Pwsh           = 'tools/selftest/echo-args-bad-stdout.ps1'
            Args           = @('0', 'alpha', 'beta')
            ExpectMismatch = @{
                Reason     = 'proves the harness fails on a stdout divergence no rule can launder'
                Dimensions = @('stdout')
            }
        }
        @{
            Name           = 'catch-state-file-content'
            Description    = 'NEGATIVE: streams identical, durable record off by one'
            Shape          = 'Script'
            Bash           = 'tools/selftest/echo-args.sh'
            Pwsh           = 'tools/selftest/echo-args-bad-state.ps1'
            Args           = @('0', 'alpha', 'beta')
            ExpectMismatch = @{
                Reason     = 'proves the harness fails on a state-file divergence invisible on both streams'
                Dimensions = @('tree')
            }
        }
        @{
            Name           = 'catch-crlf'
            Description    = 'NEGATIVE: right text, CRLF line endings in the state file'
            Shape          = 'Script'
            Bash           = 'tools/selftest/echo-args.sh'
            Pwsh           = 'tools/selftest/echo-args-crlf.ps1'
            Args           = @('0', 'alpha')
            ExpectMismatch = @{
                Reason     = 'proves line endings are never normalized away (contract 2)'
                Dimensions = @('eol', 'tree')
            }
        }
        @{
            Name           = 'catch-missing-state-file'
            Description    = 'NEGATIVE: twin never writes the durable record'
            Shape          = 'Script'
            Bash           = 'tools/selftest/echo-args.sh'
            Pwsh           = 'tools/selftest/echo-args-no-state.ps1'
            Args           = @('0', 'alpha')
            ExpectMismatch = @{
                Reason     = 'proves the harness fails on file EXISTENCE, not just content'
                Dimensions = @('tree')
            }
        }
        @{
            Name          = 'libdemo-join'
            Description   = 'Shape B: sourced bash function vs imported PS module function'
            Shape         = 'Function'
            BashLib       = 'tools/selftest/libdemo.sh'
            BashFunction  = 'fm_demo_join'
            PwshModule    = 'tools/selftest/libdemo.psm1'
            PwshFunction  = 'Invoke-FmDemoJoin'
            PwshExitFrom  = 'Return'
            Args          = @(',', 'a', 'b', 'c')
            Stdin         = ''
        }
        @{
            Name          = 'libdemo-join-empty'
            Description   = 'Shape B: the empty case must reproduce bash return 3'
            Shape         = 'Function'
            BashLib       = 'tools/selftest/libdemo.sh'
            BashFunction  = 'fm_demo_join'
            PwshModule    = 'tools/selftest/libdemo.psm1'
            PwshFunction  = 'Invoke-FmDemoJoin'
            PwshExitFrom  = 'Return'
            Args          = @(',')
            Stdin         = ''
        }
        @{
            Name           = 'catch-lost-return-code'
            Description    = 'NEGATIVE (Shape B): module twin loses the distinct return 3'
            Shape          = 'Function'
            BashLib        = 'tools/selftest/libdemo.sh'
            BashFunction   = 'fm_demo_join'
            PwshModule     = 'tools/selftest/libdemo-bad.psm1'
            PwshFunction   = 'Invoke-FmDemoJoin'
            PwshExitFrom   = 'Return'
            Args           = @(',')
            Stdin          = ''
            ExpectMismatch = @{
                Reason     = 'proves exit-code checking works through the sourced-library path too'
                Dimensions = @('exit')
            }
        }
        @{
            Name            = 'git-commit-match'
            Description     = 'git-aware: fixture BUILT per world, twins must land the same commit'
            Shape           = 'Script'
            Bash            = 'tools/selftest/commit-file.sh'
            Pwsh            = 'tools/selftest/commit-file.ps1'
            Args            = @('add the file')
            Stdin           = ''
            FixtureTemplate = $null
            FixtureScript   = 'tools/selftest/fixtures/build-repo.sh'
            Env             = @{
                FM_HOME            = '<ROOT>'
                GIT_AUTHOR_NAME    = 'fmtest'
                GIT_AUTHOR_EMAIL   = 'fmtest@example.invalid'
                GIT_COMMITTER_NAME = 'fmtest'
                GIT_COMMITTER_EMAIL = 'fmtest@example.invalid'
                GIT_AUTHOR_DATE    = '2020-01-02T00:00:00 +0000'
                GIT_COMMITTER_DATE = '2020-01-02T00:00:00 +0000'
            }
        }
        @{
            Name            = 'catch-git-history'
            Description     = 'NEGATIVE: same stdout, same working tree, different commit subject'
            Shape           = 'Script'
            Bash            = 'tools/selftest/commit-file.sh'
            Pwsh            = 'tools/selftest/commit-file-bad.ps1'
            Args            = @('add the file')
            Stdin           = ''
            FixtureTemplate = $null
            FixtureScript   = 'tools/selftest/fixtures/build-repo.sh'
            Env             = @{
                FM_HOME            = '<ROOT>'
                GIT_AUTHOR_NAME    = 'fmtest'
                GIT_AUTHOR_EMAIL   = 'fmtest@example.invalid'
                GIT_COMMITTER_NAME = 'fmtest'
                GIT_COMMITTER_EMAIL = 'fmtest@example.invalid'
                GIT_AUTHOR_DATE    = '2020-01-02T00:00:00 +0000'
                GIT_COMMITTER_DATE = '2020-01-02T00:00:00 +0000'
            }
            ExpectMismatch  = @{
                Reason     = 'proves the git-aware dimension catches repository state a file diff cannot see'
                Dimensions = @('git')
            }
        }
    )
}
