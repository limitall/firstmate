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

function New-FmTestCommittedClaudeLink {
    <#
        .SYNOPSIS
        Make a directory a git repo whose INDEX records CLAUDE.md as a symlink to
        AGENTS.md, without creating one on disk. True when the fixture was built.

        .DESCRIPTION
        The shape a Windows clone of a Linux repo actually has: the index says
        `120000 CLAUDE.md`, and the working tree has whatever git could manage
        there instead. It is what tells a mirror that has fallen behind from two
        genuinely different memory files, so Get-FmAgentsMirrorState reads it.

        Built with `update-index --cacheinfo` rather than by committing a real
        symlink, for the same reason this file exists at all: the privilege is
        not held on a stock Windows shell, and the fixture would be unbuildable
        on precisely the machine the bug happens on.

        The blob is written with NO trailing newline, which is what git stores
        for a symlink. A fixture that added one would let an implementation that
        forgets to trim pass for the wrong reason.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A Pester fixture builder: it writes only into the test directory it is given.')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$Target = 'AGENTS.md'
    )

    Set-StrictMode -Version Latest
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }

    $blob = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-link-blob-' + [Guid]::NewGuid().ToString('N'))
    try {
        $null = & git -C $Directory init -q 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        [System.IO.File]::WriteAllText($blob, $Target)
        $sha = (@(& git -C $Directory hash-object -w -- $blob 2>$null) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $sha) { return $false }
        $null = & git -C $Directory update-index --add --cacheinfo "120000,$sha,CLAUDE.md" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $blob -Force -ErrorAction SilentlyContinue
    }
}
