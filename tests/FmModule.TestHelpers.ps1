#requires -Version 7.0
# The one supported way for a test file to load THIS checkout's Firstmate module.
#
# WHY THIS EXISTS. `Import-Module <path> -Force` replaces only a module already
# loaded from the SAME path. Load a second copy of this repo - a different
# clone, a different worktree - into the same process and PowerShell keeps BOTH,
# under one name:
#
#     Import-Module C:\pbase\module\Firstmate\Firstmate.psd1   -Force  # 1 loaded
#     Import-Module C:\pbranch\module\Firstmate\Firstmate.psd1 -Force  # 2 loaded
#
# Pester then refuses every `InModuleScope Firstmate` block in the suite that
# ran second, with
#
#     Multiple script or manifest modules named 'Firstmate' are currently
#     loaded. Make sure to remove any extra copies of the module from your
#     session before testing.
#
# That is not a hypothetical. Comparing a base commit against a branch commit by
# running both suites back to back in one session - the RIGHT way to compare,
# because privilege context has to be held constant - failed exactly the 40
# tests that call InModuleScope, in whichever suite ran second, and they looked
# precisely like a regression in the second commit. They were not. The suite
# that runs second is entitled to its own module, so the import removes any
# other copy first and asserts that exactly one is left.
#
# Only the four suites that reach into module scope need this; a test that
# shells out to a child pwsh gets a clean process and is unaffected.

# NOTE ON STRICT MODE. It is set inside the function, not at file scope. A
# dot-sourced helper's top-level Set-StrictMode applies to the scope that
# dot-sourced it, so a file-scope one here would silently turn strict mode ON
# for the whole of a suite that never asked for it - and three of the four
# suites that call this do not set it themselves. That immediately broke an
# untouched FmState assertion, `(Read-FmStateLines ...).Count`, which is legal
# without strict mode and throws with it. Changing a caller's semantics from
# inside a helper is the same action-at-a-distance class of bug this file
# exists to fix, so the helper is strict about itself and nothing else.

function Import-FmTestModule {
    <#
        .SYNOPSIS
        Import the Firstmate module from THIS checkout as the only copy loaded.

        .PARAMETER TestRoot
        The tests/ directory of the checkout under test, normally $PSScriptRoot.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A test fixture that loads the module under test. -WhatIf would leave the suite running against whatever module happened to be loaded already, which is the exact failure this helper exists to prevent.')]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$TestRoot)

    Set-StrictMode -Version Latest
    $manifest = (Resolve-Path -LiteralPath (Join-Path $TestRoot '..' 'module' 'Firstmate' 'Firstmate.psd1')).ProviderPath

    # Unload every copy, including one from another checkout, before importing.
    Get-Module -Name 'Firstmate' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $manifest -Force -ErrorAction Stop

    $loaded = @(Get-Module -Name 'Firstmate')
    if ($loaded.Count -ne 1) {
        throw ("test fixture: expected exactly one loaded Firstmate module, found $($loaded.Count) " +
            "($(($loaded.Path) -join '; ')); InModuleScope cannot run against an ambiguous module name")
    }
}
