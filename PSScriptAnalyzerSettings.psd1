<#
    PSScriptAnalyzer configuration.

    Run it over the whole repository with:
        Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

    Only rules that are wrong FOR THIS REPOSITORY are excluded, each with its
    reason. Everything else is expected to pass clean; a finding is a defect to
    fix, not noise to filter.
#>
@{
    ExcludeRules = @(
        # The loader computes the exported set at import time: an explicit
        # foundation list plus every top-level function in Public/*.ps1. Naming
        # them again in the manifest would be a second source of truth that
        # several areas would have to edit in lockstep. See Firstmate.psm1.
        'PSUseToExportFieldsInManifest'

        # Read-FmStateLines and Write-FmStateLines really do handle many lines,
        # and Get-FmLockStaleAfterSeconds really is a count of seconds. A
        # singular name would misdescribe all three.
        'PSUseSingularNouns'

        # False positive against the test suite: values reach a background job
        # through Start-Job -ArgumentList and a param() block, which is the
        # explicit alternative to $using: and the only one that works for a job
        # started in an out-of-process runspace.
        'PSUseUsingScopeModifierInNewRunspaces'
    )
}
