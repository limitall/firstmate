#requires -Version 7.0
# Shared symlink-privilege probe for the test suites that create real symlinks.
#
# WHY THIS EXISTS. Creating a symlink on Windows needs SeCreateSymbolicLinkPrivilege,
# which a non-elevated shell does not hold unless Developer Mode is on. Several
# suites here build a real symlink as a FIXTURE - not as the thing under test -
# and every one of them failed on the captain's laptop with
#
#     New-Item: A required privilege is not held by the client.
#
# Eight red tests that pass when the same commit is run elevated look exactly
# like a regression, and the captain spent time on that. They are not
# regressions: they are tests whose fixture the host refuses to build.
#
# So the probe is real - it tries to create one in a temp directory - rather
# than inferred from elevation or Developer Mode, because what matters is
# whether the operation SUCCEEDS here, not which of several ways it was allowed.
# A refused fixture reports SKIPPED with the reason and the fix, which is an
# honest run; silently passing over the assertion would not be.
#
# Nothing here skips a test whose SUBJECT is symlink handling on a path that
# does not need the privilege - the CLAUDE.md placeholder repair, the hardlink
# and copy fallbacks, and every refusal path stay live on a stock Windows shell.

# NOTE ON STRICT MODE. It is set inside each function, not at file scope. A
# dot-sourced helper's top-level Set-StrictMode applies to the scope that
# dot-sourced it, so a file-scope one here would turn strict mode ON for whole
# suites that never asked for it - three of the four that call this do not set
# it themselves - and silently change assertions that have nothing to do with
# symlinks. A helper is strict about itself and leaves its caller alone.

$script:FmTestSymlinkSupported = $null

function Test-FmTestSymlinkSupported {
    <#
        .SYNOPSIS
        True when this session can actually create a symlink. Probed once.
    #>
    [OutputType([bool])]
    param()

    Set-StrictMode -Version Latest
    if ($null -ne $script:FmTestSymlinkSupported) { return $script:FmTestSymlinkSupported }

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-symlink-probe-' + [Guid]::NewGuid().ToString('N'))
    $script:FmTestSymlinkSupported = $false
    try {
        $null = New-Item -ItemType Directory -Path $probeDir -Force -ErrorAction Stop
        $target = Join-Path $probeDir 'target.txt'
        [System.IO.File]::WriteAllText($target, "probe`n")
        $link = Join-Path $probeDir 'link.txt'
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop
        $script:FmTestSymlinkSupported = [bool]((Get-Item -LiteralPath $link -Force).LinkTarget)
    } catch {
        $script:FmTestSymlinkSupported = $false
    } finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $script:FmTestSymlinkSupported
}

function Set-FmTestSymlinkSkip {
    <#
        .SYNOPSIS
        Mark the running test skipped, with the reason and the fix, when this
        session cannot create a symlink. Call it as the first line of any test
        whose FIXTURE needs one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Marks the running Pester test skipped; there is nothing to confirm and -WhatIf would leave the test running against a fixture the host refused to build.')]
    [OutputType([void])]
    param()

    Set-StrictMode -Version Latest
    if (Test-FmTestSymlinkSupported) { return }
    Set-ItResult -Skipped -Because ('this session cannot create a symlink (SeCreateSymbolicLinkPrivilege is not held), ' +
        'so the FIXTURE cannot be built - not a defect in the code under test. ' +
        'Run pwsh elevated, or turn on Windows Developer Mode, to exercise it.')
}
