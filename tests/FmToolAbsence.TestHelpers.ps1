#requires -Version 7.0
# The one way this suite makes a tool GENUINELY absent from a fixture's PATH.
#
# WHY THIS EXISTS. A fixture that simulates a missing tool builds a directory of
# stubs and puts it first on PATH. That arranges which binary wins; it does not
# arrange that the real one is unreachable. Every one of those fixtures is one
# resolution away from the real thing, and when the resolution goes the other way
# nothing says so - the fixture simply stops being a fixture and the test carries
# on against the machine.
#
# IT HAS HAPPENED HERE, AND IT WAS EXPENSIVE. Two cases in
# tests/FmModuleAssembly.Tests.ps1 stub `pwsh` so the entry points' relaunch goes
# nowhere. MEASURED 2026-09-11: the stub was not resolved, the real installer
# carried on, and because a suite has nobody at the keyboard Confirm-SpeechModel
# took its documented default - which is YES - and the run spent thirty-nine
# minutes on a 1.4 GB download before failing an assertion about something else
# entirely. The same shape, reached through a leaked PSModulePath rather than
# through PATH, hung the whole suite for 11.6 hours twice
# (docs/windows-e2e-evidence.md section 56).
#
# SO ABSENCE IS BUILT, AND THEN PROVED. Get-FmTestPathSans returns a PATH the
# named tools do not resolve on, and it resolves them against that PATH itself
# before handing it back: a fixture that would have fallen through fails HERE,
# by name, in under a second, instead of downloading something.
#
# WHY IT MIRRORS RATHER THAN DROPS. Dropping every directory that carries the
# tool is one line and is wrong: a tool sitting in System32 would take cmd,
# where, tar and findstr out with it, and the fixture would then fail for a
# reason that has nothing to do with what it is testing. So a directory that
# carries a named tool is mirrored into a curated copy WITHOUT it, by hardlink -
# no privilege on NTFS, no copy of the bytes - and the mirror stands in for it.
# Every directory that carries none of the named tools is kept exactly as it was,
# so the usual case costs nothing at all. The one this repo needs, PowerShell's
# own directory, is 320 files.
#
# THIS IS NOT THE WHOLE ANSWER FOR ANY GIVEN TOOL, and a caller must not treat it
# as one. PATH is the door most code uses; a tool that is ALSO looked for at a
# known location is still reachable through that second door, and install.ps1
# looks for pwsh under %LOCALAPPDATA%\Programs\PowerShell7 when PATH does not
# answer. CONTRIBUTING.md's rule covers it: state every variable the child
# branches on, at the seam that creates the child. This helper closes the PATH
# door and says out loud that it closes only that one.
#
# The Linux analogue is `fm_test_base_path_sans` in tests/lib.sh, which curates
# with symlinks and does not verify the result. Windows needs the verification
# more, not less: PATHEXT means one name resolves through half a dozen
# extensions, so "I removed foo" and "foo no longer resolves" are genuinely
# different statements here.

# NOTE ON STRICT MODE. Set inside each function, not at file scope, for the
# reason tests/FmModule.TestHelpers.ps1 states: a dot-sourced helper's file-scope
# Set-StrictMode applies to whichever suite dot-sourced it.

function Resolve-FmTestPathCommand {
    <#
        .SYNOPSIS
        Every file on a PATH that would answer to a bare command name.

        .DESCRIPTION
        Deliberately NOT Get-Command: that answers about the CURRENT process's
        PATH, and this has to answer about a PATH string that is being built and
        is not installed anywhere yet. Resolution order is Windows': directory by
        directory, and within a directory the bare name then each PATHEXT
        extension.

        .OUTPUTS
        System.String[] - full paths, in resolution order, empty when none.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$SearchPath,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )

    Set-StrictMode -Version Latest

    $extensions = @('')
    $pathext = [Environment]::GetEnvironmentVariable('PATHEXT')
    if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD;.PS1' }
    $extensions += @($pathext -split ';' | Where-Object { $_ })

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in ($SearchPath -split [System.IO.Path]::PathSeparator)) {
        if (-not $directory) { continue }
        foreach ($extension in $extensions) {
            $candidate = Join-Path $directory ($Name + $extension)
            # [File]::Exists rather than Test-Path, for two reasons and both
            # measured. It answers false for a path this account cannot read,
            # where Test-Path RAISES - and a real Windows PATH carries several
            # such directories, so under $ErrorActionPreference = 'Stop' the
            # provider version died on the access check instead of answering.
            # It is also about twenty times faster, and this is called once per
            # directory per extension per tool: with Test-Path, proving one tool
            # absent across a 46-entry PATH cost two seconds of the fixture's
            # time on its own.
            if ([System.IO.File]::Exists($candidate)) { $found.Add($candidate) }
        }
    }
    return , @($found)
}

function Get-FmTestPathSans {
    <#
        .SYNOPSIS
        A PATH that resolves everything -BasePath did, except the named tools -
        and that has been checked to.

        .PARAMETER BasePath
        The PATH to start from. Defaults to this process's.

        .PARAMETER Tool
        Bare command names to make unreachable, with no extension: 'pwsh', not
        'pwsh.exe'. Every PATHEXT spelling of each is removed.

        .PARAMETER Directory
        Where the curated mirrors go. A TestDrive path, so Pester reclaims them.

        .OUTPUTS
        System.String - a PATH string.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A Pester fixture builder that writes only under the caller''s TestDrive. -WhatIf would hand back a PATH the tool still resolves on, which is the exact failure this helper exists to make impossible.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Tool,
        [Parameter(Mandatory)][string]$Directory,
        [string]$BasePath = $env:PATH
    )

    Set-StrictMode -Version Latest

    $separator = [System.IO.Path]::PathSeparator
    $kept = [System.Collections.Generic.List[string]]::new()
    $index = 0

    # WHAT A PATH DIRECTORY CAN CONTRIBUTE IS A COMMAND, so those are what a
    # mirror has to carry. PowerShell's own directory is 320 files and exactly 2
    # of them are executable; hardlinking the other 318 cost eleven seconds and
    # bought nothing, because none of them was ever resolvable by name.
    #
    # THE LIMIT THIS PUTS ON A MIRROR, stated rather than discovered: a program
    # run OUT of one searches its own directory for DLLs first, and in a mirror
    # that directory holds only executables. System DLLs are unaffected (the
    # loader takes those from the system directory before it looks at anything
    # else), which covers every tool this repo hides. A fixture that needs a
    # program's private neighbours should not be mirroring that directory at all.
    $executableExtension = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $pathext = [Environment]::GetEnvironmentVariable('PATHEXT')
    if (-not $pathext) { $pathext = '.COM;.EXE;.BAT;.CMD;.PS1' }
    foreach ($extension in ($pathext -split ';' | Where-Object { $_ })) { $null = $executableExtension.Add($extension) }

    # A DUPLICATE PATH ENTRY RESOLVES NOTHING THE FIRST ONE DID NOT, and on this
    # seat PowerShell's directory is on PATH three times - which is three
    # mirrors of the same directory. Dropping the repeats keeps resolution
    # identical and makes the helper's cost proportional to the machine rather
    # than to how untidy its PATH is.
    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)

    foreach ($source in ($BasePath -split $separator)) {
        if (-not $source) { continue }
        if (-not $seen.Add($source.TrimEnd([System.IO.Path]::DirectorySeparatorChar))) { continue }
        # A DIRECTORY THIS ACCOUNT CANNOT READ IS DROPPED, not kept. A real
        # Windows PATH carries several - the system profile's WindowsApps entry
        # is on this seat's - and one that cannot be enumerated cannot be
        # mirrored, so keeping it would be keeping a directory this helper has
        # just promised to have checked. Nothing resolves out of it for this
        # account anyway, which is why it is safe as well as honest.
        # [Directory]::Exists answers false for both cases rather than raising.
        if (-not [System.IO.Directory]::Exists($source)) { continue }

        # What in THIS directory answers to one of the named tools. Resolved
        # against the single directory so the answer is about it alone.
        $offending = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $Tool) {
            foreach ($hit in (Resolve-FmTestPathCommand $source $name)) { $offending.Add($hit) }
        }
        if ($offending.Count -eq 0) {
            $kept.Add($source)
            continue
        }

        $index++
        $mirror = Join-Path $Directory ('sans-{0:d2}' -f $index)
        $null = New-Item -ItemType Directory -Path $mirror -Force
        $excluded = @($offending | ForEach-Object { (Split-Path -Leaf $_) })
        foreach ($entry in (Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue)) {
            if ($excluded -contains $entry.Name) { continue }
            # An extensionless file is kept because that is what an executable
            # looks like everywhere except Windows, and this file is dot-sourced
            # on both.
            if ($entry.Extension -and -not $executableExtension.Contains($entry.Extension)) { continue }
            $link = Join-Path $mirror $entry.Name
            if (Test-Path -LiteralPath $link) { continue }
            try {
                $null = New-Item -ItemType HardLink -Path $link -Value $entry.FullName -ErrorAction Stop
            } catch {
                # A different volume, or a filesystem with no hardlinks. Copying
                # is slower and correct; a directory this helper could not mirror
                # at all would be a directory it silently dropped.
                try { Copy-Item -LiteralPath $entry.FullName -Destination $link -ErrorAction Stop }
                catch { Write-Verbose "Get-FmTestPathSans: could not mirror $($entry.FullName): $_" }
            }
        }
        $kept.Add($mirror)
    }

    $result = ($kept -join $separator)

    # THE PROOF, and the reason to use this rather than editing a PATH by hand.
    # A fixture whose absent tool is still reachable fails here, naming the file
    # that would have answered, instead of quietly running it.
    foreach ($name in $Tool) {
        # ASSIGNED, NOT WRAPPED. Resolve-FmTestPathCommand returns its list
        # behind a unary comma so an empty one cannot unroll to $null, and
        # @(...) round that would collect the ONE array-shaped object into a
        # one-element array - so an empty result would read as "one thing
        # resolved" and this proof would throw on every correct call.
        # CONTRIBUTING.md owns the rule; this is the caller-side half of it.
        $reachable = Resolve-FmTestPathCommand $result $name
        if ($reachable.Count -gt 0) {
            throw ("test fixture: Get-FmTestPathSans was asked to make '$name' unreachable and it is still " +
                "resolved by $($reachable[0]); the fixture would have run the real tool")
        }
    }
    $result
}
