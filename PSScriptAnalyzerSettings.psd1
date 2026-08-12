<#
    PSScriptAnalyzer configuration - the ONE bar the whole repository is held to.

    Run it over everything with:
        Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

    tests/FmAnalyzer.Tests.ps1 runs exactly that sweep as part of the Pester
    suite, so the bar is enforced on every test run rather than only when
    someone remembers the command.

    THE RULE FOR CHANGING THIS FILE. A finding is a defect to fix, not noise to
    filter. Only a rule that is wrong for THIS repository is excluded, and only
    with its reason written below; where the rule is wrong for one function
    rather than the whole repo, suppress it at that function with a
    Justification instead - the suite checks that every suppression carries one.
    Do not add a tolerated count anywhere: the repository once reached 814
    findings precisely because each area measured only its own files.
#>
@{
    ExcludeRules = @(
        # The loader computes the exported set at import time: an explicit
        # foundation list plus every top-level function in Public/*.ps1. Naming
        # them again in the manifest would be a second source of truth that
        # several areas would have to edit in lockstep. See Firstmate.psm1.
        'PSUseToExportFieldsInManifest'

        # 21 functions across every area, and the plural is right in all of
        # them: they return collections (Read-FmStateLines, Get-FmWakeQueueLines,
        # Get-FmSessionPaths, Get-FmWatchSignalChanges) or count units rather
        # than name a noun (Get-FmLockStaleAfterSeconds,
        # Get-FmClassifyPauseResurfaceSecs). A singular name would misdescribe
        # what each one hands back.
        'PSUseSingularNouns'

        # False positive against the test suite (FmLock, FmState and FmIdentity
        # spawn real background processes on purpose): values reach a background
        # job through Start-Job -ArgumentList and a param() block, which is the
        # explicit alternative to $using: and the only one that works for a job
        # started in an out-of-process runspace.
        'PSUseUsingScopeModifierInNewRunspaces'
    )

    Rules        = @{
        # AGENTS.md requires Join-Path over a hard-coded separator, so a
        # multi-segment path is written as Join-Path <root> <a> <b>. Spelling
        # that as -Path/-ChildPath/-AdditionalChildPath is longer and reads
        # worse, and the segment order is not ambiguous. Every OTHER command
        # still has to name its parameters past the second one.
        PSAvoidUsingPositionalParameters = @{
            Enable           = $true
            CommandAllowList = @('Join-Path')
        }
    }
}
