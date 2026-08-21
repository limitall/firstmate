#requires -Version 7.0
# FmMachine.ps1 - the two things a tool install does not cover, and the pass that
# proves the whole machine.
#
# WHAT "VERIFIED" HAS TO MEAN HERE. An installer that ends with "Installed." and
# has checked nothing is the thing this area exists to avoid: every failure it
# could have caught is instead discovered later, by the captain, as a command
# that behaves oddly. So the run ends by EXERCISING the machine - every tool is
# run and made to print a version, the operating contract is read and measured,
# the skills are counted, and the repository's own test suite is executed - and
# the verdict is computed from what those returned.
#
# The suite is the last check and the strongest one. It is also the only check
# that costs minutes rather than seconds, which is why -SkipSuite exists; a run
# that skipped it says so in its verdict rather than claiming a pass it did not
# take.

Set-StrictMode -Version Latest

# --- the `firstmate` command ---------------------------------------------------

# NOT %LOCALAPPDATA%\Microsoft\WindowsApps, which is the obvious choice and does
# not work: it is a reparse point Windows reserves for App Execution Aliases, and
# a plain .cmd dropped there is not resolved by the shell even though the folder
# IS on PATH and the file IS present. Measured - `firstmate` came back "not
# recognized" from a cmd.exe given a freshly rebuilt PATH.
#
# A dedicated per-user directory, added to PATH explicitly, is predictable and
# still needs no elevation.
function Get-FmMachineShimDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$InstallRoot = '')

    if (-not $InstallRoot) {
        if (-not $env:LOCALAPPDATA) { throw 'error: LOCALAPPDATA is not set, so there is no per-user place for the firstmate command' }
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    }
    Join-Path $InstallRoot 'firstmate'
}

function Get-FmMachineShimText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StartScript)

    # A .cmd rather than a .ps1: this is what makes a bare `firstmate` work from
    # cmd.exe, from the Run box and from a PowerShell session alike. %* carries
    # the captain's own arguments through to start.ps1.
    @(
        '@echo off'
        "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$StartScript`" %*"
    ) -join "`r`n"
}

function Set-FmMachineCommandShim {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$InstallRoot = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User'
    )

    $binDirectory = Get-FmMachineShimDirectory -InstallRoot $InstallRoot
    $startScript = Join-Path $RepoRoot 'start.ps1'
    $shimPath = Join-Path $binDirectory 'firstmate.cmd'
    $text = Get-FmMachineShimText -StartScript $startScript

    $current = ''
    if (Test-Path -LiteralPath $shimPath -PathType Leaf) { $current = [System.IO.File]::ReadAllText($shimPath) }
    if ($current -eq $text -and (Test-FmToolOnPath -Directory $binDirectory -Scope $PathScope)) {
        return [pscustomobject]@{ Action = 'already'; Detail = "$shimPath -> $startScript" }
    }
    if (-not $PSCmdlet.ShouldProcess($shimPath, 'write the firstmate command')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }

    if (-not (Test-Path -LiteralPath $binDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $binDirectory -Force
    }
    $action = if (Test-Path -LiteralPath $shimPath -PathType Leaf) { 'updated' } else { 'created' }
    [System.IO.File]::WriteAllText($shimPath, $text)
    $null = Add-FmToolUserPath -Directory $binDirectory -Scope $PathScope -Confirm:$false
    [pscustomobject]@{ Action = $action; Detail = "$shimPath -> $startScript" }
}

# --- PowerShell 7, findable ------------------------------------------------------
#
# WHY THIS EXISTS. `install.ps1` installs PowerShell 7 with Microsoft's own
# install-powershell.ps1 pointed at `%LOCALAPPDATA%\Programs\PowerShell7`,
# because that is the route that needs no administrator - and that route EXPANDS
# A ZIP. It writes `pwsh.exe`, it puts the directory on the user PATH, and it
# registers nothing at all. The vendor's MSI is what creates a Start menu entry,
# and the MSI is machine-scope.
#
# MEASURED on the captain's clean Windows 11 machine, 2026-08-20: the run said
# PowerShell 7 was installed, re-launched itself under
# `C:\Users\<them>\AppData\Local\Programs\PowerShell7\pwsh.exe`, and there was no
# Start menu entry and no other way to open it the way a person opens an
# application. Being told "installed" and then not being able to find the thing
# is not installed.
#
# A `.lnk` in the USER's own Start Menu\Programs folder is what Start and its
# search box read, and writing one needs no elevation - so the no-administrator
# rule is kept AND the captain can find it. `install.ps1` additionally prints
# where the executable went and the one elevated command that gets the vendor's
# fully registered install, for a captain who wants the Windows Terminal profile
# and the context-menu entries that only the MSI can add.
#
# IT NEVER WRITES A SECOND ONE. A machine that got PowerShell 7 from the MSI
# already carries `PowerShell\PowerShell 7 (x64).lnk` under the machine-wide
# Start Menu - measured on this machine - so both folders are searched, and
# searched RECURSIVELY, because the vendor nests its entry in a subfolder.

# The Start menu folders, in the order they matter: the user's own first,
# because that is the one that can be written without administrator, then the
# machine-wide one, which is searched and never written.
function Get-FmMachineStartMenuDirectory {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $folders = @()
    foreach ($name in @('Programs', 'CommonPrograms')) {
        $path = [string][Environment]::GetFolderPath($name)
        if ($path) { $folders += $path }
    }
    [string[]]$folders
}

# The path of a Start menu shortcut that already launches this executable, or ''.
#
# It reads each .lnk's real target rather than matching on the shortcut's name:
# the vendor calls its entry "PowerShell 7 (x64)", a captain may have renamed
# theirs, and what decides whether the captain can already find PowerShell 7 is
# what the shortcut POINTS AT.
function Get-FmMachineShellShortcut {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Directory
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($folder in $Directory) {
            if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
            $links = @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse -Force -ErrorAction SilentlyContinue)
            foreach ($link in $links) {
                $target = ''
                try { $target = [string]$shell.CreateShortcut($link.FullName).TargetPath } catch { $target = '' }
                if ($target -and (Test-FmPathEqual -Left $target -Right $PwshPath)) { return $link.FullName }
            }
        }
    } catch {
        # A machine whose scripting host refuses is a machine where nothing can
        # be read AND nothing can be written, so the caller's create attempt is
        # about to report the same refusal with the same detail. Answering
        # "none found" here keeps that one report rather than making two.
        return ''
    } finally {
        if ($shell) { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    ''
}

# Put PowerShell 7 in the Start menu, unless something already did.
#
# -PwshPath defaults to the shell this is running in, which after install.ps1's
# relaunch IS the PowerShell 7 that was just installed. -StartMenuDirectory is
# the suite's seam: the first entry is where a new shortcut is written and every
# entry is searched, so the real .lnk can be created and read back against
# disposable directories without touching the captain's Start menu.
function Set-FmMachineShellShortcut {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$PwshPath = '',
        [string[]]$StartMenuDirectory = @(),
        [string]$Name = 'PowerShell 7'
    )

    $none = [pscustomobject]@{ Action = 'skipped'; Detail = ''; PwshPath = $PwshPath; Shortcut = '' }
    if (-not $IsWindows) {
        $none.Detail = 'not Windows; a Start menu entry is a Windows thing'
        return $none
    }
    if (-not $PwshPath) { $PwshPath = [string](Get-Process -Id $PID).Path }
    $none.PwshPath = $PwshPath
    if (-not $PwshPath -or -not (Test-Path -LiteralPath $PwshPath -PathType Leaf)) {
        $none.Detail = "this shell reports no executable path, so there is nothing to point a shortcut at"
        return $none
    }

    $directories = @($StartMenuDirectory | Where-Object { $_ })
    if ($directories.Count -eq 0) { $directories = @(Get-FmMachineStartMenuDirectory) }
    if ($directories.Count -eq 0) {
        $none.Detail = 'no Start menu folder resolves on this machine'
        return $none
    }

    $existing = Get-FmMachineShellShortcut -PwshPath $PwshPath -Directory $directories
    if ($existing) {
        return [pscustomobject]@{
            Action   = 'already'
            Detail   = "in Start as '$([System.IO.Path]::GetFileNameWithoutExtension($existing))' -> $PwshPath"
            PwshPath = $PwshPath
            Shortcut = $existing
        }
    }

    $shortcutPath = Join-Path $directories[0] ($Name + '.lnk')
    if (-not $PSCmdlet.ShouldProcess($shortcutPath, "add $Name to the Start menu")) {
        $none.Detail = 'WhatIf'
        return $none
    }

    $shell = $null
    try {
        if (-not (Test-Path -LiteralPath $directories[0] -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directories[0] -Force
        }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $PwshPath
        $shortcut.WorkingDirectory = [string]$env:USERPROFILE
        $shortcut.IconLocation = "$PwshPath,0"
        $shortcut.Description = 'PowerShell 7 - the shell firstmate runs in'
        $shortcut.Save()
    } catch {
        # NOT a failure of the install. The tool is on disk and on PATH; what
        # could not be added is the convenience of finding it in Start, so the
        # report says where it is and how to start it instead.
        return [pscustomobject]@{
            Action   = 'skipped'
            Detail   = ("could not add it to the Start menu ($([string]$_.Exception.Message)). " +
                "It is installed at $PwshPath - start it by running 'pwsh' in a NEW window")
            PwshPath = $PwshPath
            Shortcut = ''
        }
    } finally {
        if ($shell) { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    [pscustomobject]@{
        Action   = 'created'
        Detail   = "in Start as '$Name' -> $PwshPath"
        PwshPath = $PwshPath
        Shortcut = $shortcutPath
    }
}

# Where PowerShell 7 is and how a person opens it, said out loud in the report.
#
# The shortcut above is the answer to "can the captain find it"; this is the
# answer to "and were they told". They are not the same thing: the captain who
# hit this was told the install succeeded and left to search for it, so the run
# now names the executable, names the Start entry, and - where nothing but the
# machine-wide installer can add the Windows Terminal profile and the
# right-click entries - gives the ONE elevated command that does, rather than
# leaving that as something they have to know.
function Get-FmMachineShellLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Shortcut)

    if (-not $IsWindows) { return [string[]]@() }

    [string[]]$lines = @('PowerShell 7 - the shell everything here runs in:')
    if ($Shortcut.PwshPath) {
        $lines += "  installed at  $($Shortcut.PwshPath)"
    }
    switch ($Shortcut.Action) {
        'created' { $lines += '  open it from  Start, as "PowerShell 7" - or type pwsh in any NEW window' }
        'already' { $lines += "  open it from  Start, as `"$([System.IO.Path]::GetFileNameWithoutExtension($Shortcut.Shortcut))`" - or type pwsh in any NEW window" }
        default { $lines += '  open it from  a NEW window, by typing pwsh' }
    }
    if ($Shortcut.Action -ne 'already') {
        # A per-user install is a zip expansion: it registers no Windows
        # Terminal profile and no Explorer context-menu entries, and nothing
        # without administrator can add them. Naming the command is the honest
        # answer; installing over the captain's machine is not.
        $lines += '  the Windows Terminal profile and the right-click entries need the machine-wide'
        $lines += '  installer, which is the one thing here that needs administrator. Optional, once:'
        $lines += ('      ' + (Get-FmBootstrapWingetCommand -PackageId 'Microsoft.PowerShell'))
    }
    $lines
}

# --- the suite -----------------------------------------------------------------

# --- where this checkout is ------------------------------------------------------
#
# THE FIFTH THING THE CAPTAIN STILL DID BY HAND. A clone in the wrong place is
# refused before any of this runs, and the refusal never says "wrong place" - it
# says "access is denied" two thirds of the way through, from whichever step
# happened to be the first one to write something. This asks the question at the
# top, in one place, and answers it by WRITING rather than by guessing: the only
# proof that a directory can be installed into is a write it accepted.
#
# THREE THINGS MAKE A LOCATION UNUSABLE, and they are told apart because the
# remedy differs:
#
#   a refused write   proved here, by doing it. Nothing else can be established
#                     about a directory this machine will not let us touch.
#   a network or
#   removable drive   the per-user command this install writes points at the
#                     checkout's own start.ps1, and a drive that is not always
#                     there makes that command intermittent.
#   a synced folder   OneDrive replaces files with placeholders on demand and
#                     does not carry a junction or a symlink. This repo commits
#                     two links and VERIFIES them at the end of every install, so
#                     a checkout under OneDrive fails a check nothing here can
#                     fix from inside.
#
# AND ONE MAKES IT A WARNING, not a refusal. Controlled folder access protects
# Documents, Desktop and the other known folders, and it is OFF by default - so a
# checkout there works on most machines and is refused on some, which is exactly
# the case that must be NAMED rather than either ignored or refused outright.
function Get-FmMachineLocationCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $suggestion = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'firstmate-win' } else { 'a directory in your own profile' }
    $concerns = [System.Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{
        Path       = $Path
        Usable     = $true
        Reason     = ''
        Suggestion = $suggestion
        Concerns   = @()
    }

    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { Write-Debug "could not normalize '$Path': $_" }
    $result.Path = $full

    # 1. a place that is not always there.
    if ($full.StartsWith('\\')) {
        $result.Usable = $false
        $result.Reason = ('this checkout is on a network share. The one-word command this install writes points straight ' +
            'at start.ps1 here, so it works only while the share is mounted, and Windows applies a stricter execution ' +
            'policy to scripts that come from one.')
        $result.Concerns = @($result.Reason)
        return $result
    }
    if ($IsWindows) {
        try {
            $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($full))
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
                # IN THE CAPTAIN'S WORDS, NOT .NET'S. "NoRootDirectory" is the
                # enum name for a drive letter nothing is mounted on, and
                # printing it tells a person nothing about what to do.
                $what = switch ($drive.DriveType) {
                    ([System.IO.DriveType]::NoRootDirectory) { 'a drive letter with nothing mounted on it' }
                    ([System.IO.DriveType]::Removable) { 'a removable drive' }
                    ([System.IO.DriveType]::Network) { 'a network drive' }
                    ([System.IO.DriveType]::CDRom) { 'a disc, which cannot be written to' }
                    ([System.IO.DriveType]::Ram) { 'a RAM disk, which does not survive a restart' }
                    default { "a $($drive.DriveType) drive" }
                }
                $result.Usable = $false
                $result.Reason = ("this checkout is on $what. The one-word command this install writes points straight " +
                    'at start.ps1 here, so it stops working the moment that drive is not there.')
                $result.Concerns = @($result.Reason)
                return $result
            }
        } catch {
            Write-Debug "could not read the drive behind '$full': $_"
        }
    }

    # 2. a folder something else is syncing.
    $syncRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ }
    $inSync = @($syncRoots | Where-Object { Test-FmMachinePathUnder -Path $full -Parent $_ }).Count -gt 0
    if (-not $inSync) {
        $inSync = @(($full -split '[\\/]') | Where-Object { $_ -ieq 'OneDrive' -or $_ -imatch '^OneDrive - ' }).Count -gt 0
    }
    if ($inSync) {
        $result.Usable = $false
        $result.Reason = ('this checkout is inside a OneDrive folder. OneDrive turns files into placeholders it fetches on ' +
            'demand and does not carry a junction or a symlink, and this repo commits two links that every install ' +
            'repairs and then verifies - so that verification fails here for a reason nothing in this repo can fix.')
        $result.Concerns = @($result.Reason)
        return $result
    }

    # 3. a folder Windows guards when the captain has switched that guard on.
    foreach ($known in @('MyDocuments', 'Desktop', 'MyPictures', 'MyVideos', 'MyMusic', 'Favorites')) {
        $folder = ''
        try { $folder = [System.Environment]::GetFolderPath($known) } catch { Write-Debug "no known folder '$known': $_" }
        if (-not $folder) { continue }
        if (-not (Test-FmMachinePathUnder -Path $full -Parent $folder)) { continue }
        $concerns.Add(("this checkout is inside $folder, which Controlled folder access protects when it is switched on. " +
                'It is off by default, so this usually works - and where it is on, the write below is what finds out.'))
    }

    # 4. THE ONLY PROOF: a write this machine accepted. A directory as well as a
    #    file, because the install creates both and a guard can allow one.
    # NOTHING IS CREATED TO ANSWER A QUESTION ABOUT WHAT IS THERE. The probe
    # below uses -Force, which would build the whole missing chain - so a path
    # that does not exist is answered rather than brought into being by a
    # function whose entire job is to look.
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        $result.Usable = $false
        $result.Reason = 'there is no directory at this path, so there is nothing to install into.'
        $concerns.Add($result.Reason)
        $result.Concerns = @($concerns)
        return $result
    }

    # -WhatIf:$false ON BOTH HALVES, and this is not a liberty taken lightly.
    # A WhatIf run still has to DETECT, and this probe is detection: it makes a
    # directory and a file and removes both, so it changes nothing to report on.
    # Half-honouring WhatIf is what breaks it - New-Item obeys the preference and
    # creates nothing, the raw .NET write beneath it does not obey anything and
    # fails on the directory that was never made, and the run then reports the
    # captain's perfectly good checkout as one this machine REFUSED. Measured
    # here: Install-FmMachine -WhatIf called this checkout unusable.
    $probe = Join-Path $full ('.fm-location-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType Directory -Path $probe -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        [System.IO.File]::WriteAllText((Join-Path $probe 'probe.txt'), 'probe')
    } catch {
        $result.Usable = $false
        $result.Reason = ("this machine refused a write into the checkout: $($_.Exception.Message) Nothing can be installed " +
            'into a directory that will not accept a file. Security software and Controlled folder access, which protects ' +
            'Documents, are the two that refuse a write this way.')
        $concerns.Add($result.Reason)
        $result.Concerns = @($concerns)
        return $result
    } finally {
        # The same, for the same reason: a removal that WhatIf skipped would
        # leave the probe behind in the captain's own checkout.
        if (Test-Path -LiteralPath $probe) {
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        }
    }

    $result.Concerns = @($concerns)
    if ($concerns.Count -eq 0) {
        $result.Reason = 'a plain local directory, and this machine accepted a write into it'
    } else {
        $result.Reason = 'this machine accepted a write into it, and the note above says what could still guard it'
    }
    $result
}

# Is $Path inside $Parent? Compared as normalized full paths with a trailing
# separator, so C:\Users\me\Documents2 is not read as being under
# C:\Users\me\Documents.
function Test-FmMachinePathUnder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Parent
    )

    if (-not $Parent) { return $false }
    try {
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $child = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + $separator
        $root = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + $separator
        return $child.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        Write-Debug "could not compare '$Path' against '$Parent': $_"
        return $false
    }
}

# The location, as one line of the install's own verification vocabulary.
function Get-FmMachineLocationVerification {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Location)

    if (-not $Location.Usable) {
        return New-FmInstallCheck -Name 'checkout location' -Status 'missing' -Required `
            -Detail "$($Location.Path) - $($Location.Reason)" `
            -Fix "clone it somewhere the machine does not guard, and run install.ps1 there: git clone <this repo> `"$($Location.Suggestion)`""
    }
    if (@($Location.Concerns).Count -gt 0) {
        return New-FmInstallCheck -Name 'checkout location' -Status 'warn' `
            -Detail "$($Location.Path) - $(@($Location.Concerns)[0])" `
            -Fix "if anything below is refused, clone into `"$($Location.Suggestion)`" instead"
    }
    New-FmInstallCheck -Name 'checkout location' -Status 'ok' -Detail "$($Location.Path) - $($Location.Reason)"
}

# CAN THE SUITE RUN AT ALL, decided before a process is started for it.
#
# THE VERSION, NOT MERELY THE NAME. Windows ships Pester 3.4.0 on every machine,
# so "Pester is installed" is true on a machine that cannot run this suite - and
# the child process then died on `Import-Module Pester -MinimumVersion 5.0.0`,
# printing a raw PowerShell error with a source-line caret into the middle of the
# captain's install log. MEASURED there, 2026-08-21. That was the SECOND time the
# run reported the same fact: the plan had already said 3.4.0 was below the floor,
# cleanly, two lines earlier. A condition this run has detected and reported must
# not also escape as noise.
#
# Split from the run so the decision is exercisable against a version list rather
# than only against whatever this machine happens to have installed.
function Get-FmMachineSuitePrerequisite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][version[]]$Available = @())

    $newest = @($Available | Sort-Object -Descending | Select-Object -First 1)
    if ($newest.Count -eq 0) {
        return [pscustomobject]@{ CanRun = $false; Newest = ''; Detail = 'Pester is not installed, so the suite could not run' }
    }
    if ($newest[0].Major -lt 5) {
        return [pscustomobject]@{
            CanRun = $false
            Newest = $newest[0].ToString()
            Detail = "the newest Pester on this machine is $($newest[0]), and this suite is written for Pester 5+, so it could not run"
        }
    }
    [pscustomobject]@{ CanRun = $true; Newest = $newest[0].ToString(); Detail = '' }
}

# Run in a CHILD process on purpose. The suite imports the module, rewrites
# PSModulePath and sets environment variables of its own; running it inside the
# session that just performed an install would leave that session's view of the
# machine decided by the tests rather than by the install. It also means a suite
# that crashes outright is reported as a failed verification rather than taking
# the installer down with it.
function Invoke-FmMachineSuite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$TimeoutSeconds = 3600
    )

    $testsPath = Join-Path $RepoRoot 'tests'
    if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
        return [pscustomobject]@{ Ran = $false; Passed = 0; Failed = 0; Detail = "no tests directory at '$testsPath'"; FailedNames = @() }
    }
    $prerequisite = Get-FmMachineSuitePrerequisite -Available @(Get-Module -ListAvailable -Name 'Pester' | ForEach-Object { $_.Version })
    if (-not $prerequisite.CanRun) {
        return [pscustomobject]@{ Ran = $false; Passed = 0; Failed = 0; Detail = $prerequisite.Detail; FailedNames = @() }
    }

    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-suite-' + [guid]::NewGuid().ToString('N') + '.json')
    $runner = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-suite-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $errorPath = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-suite-' + [guid]::NewGuid().ToString('N') + '.err')
    [System.IO.File]::WriteAllText($runner, @'
param([Parameter(Mandatory)][string]$Tests, [Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference = 'Continue'
try {
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
} catch {
    [pscustomobject]@{ Passed = 0; Failed = 0; Skipped = 0; FailedNames = @(); Refused = [string]$_.Exception.Message } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
    exit 1
}
$configuration = New-PesterConfiguration
$configuration.Run.Path = $Tests
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $configuration
$failed = @($result.Failed | ForEach-Object { [string]$_.ExpandedPath })
[pscustomobject]@{
    Passed      = [int]$result.PassedCount
    Failed      = [int]$result.FailedCount
    Skipped     = [int]$result.SkippedCount
    FailedNames = $failed
    Refused     = ''
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
'@, [System.Text.UTF8Encoding]::new($false))

    try {
        # BOUNDED. A wedged test would otherwise hang the installer with no
        # output and nothing to act on, at the exact moment the captain is
        # waiting to be told whether the machine works.
        $pwsh = (Get-Process -Id $PID).Path
        # A REFUSED LAUNCH IS A VERDICT, NOT A CRASH. This is the last step of
        # the install, so an unguarded start here would throw away the whole
        # report the captain is waiting for over a machine that declined to open
        # one more process.
        try {
            # THE CHILD'S ERROR STREAM GOES TO A FILE, NOT TO THE CAPTAIN. With
            # -NoNewWindow and no redirection it writes straight onto the console
            # this run is composing a report on, which is how a handled Pester
            # failure arrived in the captain's log as a raw error with a
            # source-line caret. Whatever it says is read back below and folded
            # into this function's own verdict instead.
            # -ExecutionPolicy Bypass because the runner IS A FILE, and a file
            # is the one thing Windows' default policy refuses. install.ps1's
            # documented first command carries the same switch for the same
            # reason, and a run started from a window that is already PowerShell
            # 7 never passes through the relaunch that would hand it down - so
            # without this, the step that PROVES the install is the one thing a
            # locked-down machine declines to run.
            # -NonInteractive BECAUSE AN INSTALLER MUST NEVER BE ABLE TO ASK A
            # QUESTION. -NoNewWindow hands this child the captain's own console,
            # so a host that CAN prompt will: a test that omits a mandatory
            # parameter on purpose - which is how the suite proves a refusal -
            # binds by prompting instead of failing, and the install stops dead
            # on "Supply values for the following parameters:" with nothing on
            # screen to say what is being asked or why. MEASURED, and recorded
            # in docs/windows-e2e-evidence.md section 39: the same call in a
            # console child hangs forever without this switch and throws
            # MissingMandatoryParameter with it. It turns any prompt this suite
            # can reach - not only that one - from a dead install into one named
            # test failure the captain can read.
            $process = Start-Process -FilePath $pwsh -NoNewWindow -PassThru -RedirectStandardError $errorPath -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Tests', $testsPath, '-ResultPath', $resultPath)
        } catch {
            Write-Debug "could not start the suite process: $_"
            return [pscustomobject]@{
                Ran         = $false
                Passed      = 0
                Failed      = 0
                Detail      = (Get-FmToolLaunchRefusal -Program $pwsh `
                        -Consequence 'the suite was never started, so this install is not proven by it' `
                        -Remedy "Run it yourself: Invoke-Pester -Path '$testsPath'.")
                FailedNames = @()
            }
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Debug "could not stop the suite process: $_" }
            return [pscustomobject]@{
                Ran         = $false
                Passed      = 0
                Failed      = 0
                Detail      = "the suite did not finish within $TimeoutSeconds seconds and was stopped"
                FailedNames = @()
            }
        }
        # WHATEVER THE CHILD SAID, SAID ONCE AND IN THIS FUNCTION'S WORDS.
        $said = ''
        if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
            $said = ([System.IO.File]::ReadAllText($errorPath)).Trim()
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            $detail = "the suite process produced no result file (exit code $($process.ExitCode))"
            if ($said) {
                $firstLines = @($said -split "`r`n|`n" | Where-Object { $_.Trim() } | Select-Object -First 3)
                $detail += '. It said: ' + ($firstLines -join ' ')
            }
            return [pscustomobject]@{ Ran = $false; Passed = 0; Failed = 0; Detail = $detail; FailedNames = @() }
        }
        $parsed = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        # The runner writes a result file even when it could not start Pester, so
        # that refusal arrives here as a verdict rather than as an error on the
        # captain's console.
        $refused = if ($parsed.PSObject.Properties.Name -contains 'Refused') { [string]$parsed.Refused } else { '' }
        if ($refused) {
            return [pscustomobject]@{
                Ran         = $false
                Passed      = 0
                Failed      = 0
                Detail      = "the suite could not start Pester: $refused"
                FailedNames = @()
            }
        }
        $names = @($parsed.FailedNames)
        return [pscustomobject]@{
            Ran         = $true
            Passed      = [int]$parsed.Passed
            Failed      = [int]$parsed.Failed
            Detail      = "$([int]$parsed.Passed) passed, $([int]$parsed.Failed) failed, $([int]$parsed.Skipped) skipped"
            FailedNames = $names
        }
    } finally {
        foreach ($temp in @($runner, $resultPath, $errorPath)) {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }
}

# --- the proving pass ----------------------------------------------------------

# Every tool in the catalog, run and made to answer.
#
# PRESENT IS NOT ENOUGH. A command that resolves but prints no version is
# reported as unverified, because that is exactly the shape a wrong package takes
# - the npm `herdr` placeholder installs a `herdr` that does nothing. Required
# tools that fail this are 'missing'; optional ones are 'warn', because a machine
# without gh is a working firstmate that cannot open a PR.
#
# DELIBERATELY OFFLINE. This asks "does this machine work", not "is it the newest
# version": a tool one release behind is a working tool, and the verdict on a
# finished install must not depend on whether a vendor's API answered.
# Get-FmMachineInstallPlan is where currency is asked about.
function Get-FmMachineToolVerification {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$SkipOptional)

    $checks = @()
    foreach ($entry in (Get-FmToolCatalog)) {
        if ($SkipOptional -and -not $entry.Required) { continue }
        $status = Get-FmToolStatus -Command $entry.Command
        $minimum = Get-FmToolMinimum -Tool $entry.Tool
        $capabilityMet = if ($status.Present -and $status.Launchable) { Test-FmToolCapability -Tool $entry.Tool } else { $true }
        $classification = Get-FmToolClassification -Present $status.Present -Installed $status.Version `
            -Minimum $minimum.Version -CapabilityMet $capabilityMet -Launchable $status.Launchable
        $name = "tool $($entry.Label)"
        $status_ = if ($entry.Required) { 'missing' } else { 'warn' }
        $fix = Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool $entry.Tool)

        switch ($classification) {
            'missing' {
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required `
                    -Detail "not on PATH - $($entry.Why)" -Fix $fix
            }
            'unsupported' {
                $detail = if ($minimum.Capability) {
                    "$($status.Version) is installed, and this port needs a build that $($minimum.Capability)"
                } else {
                    "$($status.Version) is installed; this repo requires at least $($minimum.Version) ($($minimum.Source))"
                }
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required -Detail $detail -Fix $fix
            }
            'unknown-version' {
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required `
                    -Detail (Get-FmToolUnprovenDetail -Command $entry.Command -Path $status.Path -ExitCode $status.ExitCode) `
                    -Fix $fix
            }
            # NOT the same finding as the one above, and saying so matters: that
            # one ran and printed nothing useful, this one never ran at all.
            'unusable' {
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required `
                    -Detail (Get-FmToolLaunchRefusal -Program $status.Path `
                        -Consequence "'$($entry.Command)' could not be exercised, so this install is not proven" `
                        -Remedy "Open a new window and run '$($entry.Command) --version' yourself.") `
                    -Fix $fix
            }
            default {
                $checks += New-FmInstallCheck -Name $name -Status 'ok' -Required:$entry.Required `
                    -Detail "$($status.Version) - $($status.Path)"
            }
        }
    }
    $checks
}

# The opt-in channels, reported and never touched.
#
# THE CAPTAIN'S NAME, THE PHONE CHANNEL AND THE SPEECH ENGINE ARE OPTIONAL, and
# an installer that quietly half-set one would be worse than one that ignored
# them: a `config/telegram-token` with no `config/telegram-allow` is a channel
# that looks configured and refuses every message, and a `config/voice` written
# by a script nobody asked is a machine that starts talking. So this WRITES
# NOTHING. It reports each one as on or off, with the one command that turns it
# on, and it returns LINES rather than checks - an off channel is a state, not a
# fault, and must not colour the run's verdict.
function Get-FmMachineOptionalLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $configDir = Get-FmInstallConfigDirectory -FirstmateHome $FirstmateHome
    $read = {
        param([string]$Name)
        $path = Join-Path $configDir $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        ([System.IO.File]::ReadAllText($path)).Trim()
    }

    $lines = @('optional - reported as it is, never assumed and never half-set:')

    $name = & $read 'captain-name'
    $lines += if ($name) {
        '  [on]       captain''s name - firstmate calls you "' + $name + '"'
    } else {
        '  [off]      captain''s name - no config/captain-name, so firstmate says "captain"; set it with bin/fm-name.ps1 <name>'
    }

    $voice = & $read 'voice'
    $lines += if ($voice) {
        '  [on]       voice - config/voice is present, so bin/fm-say.ps1 and bin/fm-ask.ps1 will speak and listen'
    } else {
        '  [off]      voice - no config/voice, so nothing is spoken and the microphone is never opened'
    }

    # BOTH halves, because either alone is the half-set state. A token with no
    # allow-list is a channel that looks configured and refuses every message.
    $token = & $read 'telegram-token'
    $allow = & $read 'telegram-allow'
    $lines += if ($token -and $allow) {
        '  [on]       phone channel - config/telegram-token and config/telegram-allow are both present'
    } elseif ($token -or $allow) {
        '  [partial]  phone channel - only one of config/telegram-token and config/telegram-allow is set, so it will refuse every message; set both or neither'
    } else {
        '  [off]      phone channel - no config/telegram-token, so bin/fm-tell.ps1 sends nothing and nothing is ever received'
    }

    $lines
}

function Get-FmMachineModuleVerification {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $checks = @()
    foreach ($requirement in (Get-FmToolModuleRequirement)) {
        $status = Get-FmToolModuleStatus -Requirement $requirement
        $name = "module $($requirement.Name)"
        # -Supersedable for the same reason the plan sets it: a module below the
        # floor is one this run installs beside what is there, so it must not be
        # classified here as the kind that gets told and skipped.
        $classification = Get-FmToolClassification -Present $status.Present -Installed $status.Version `
            -Minimum $requirement.MinimumVersion -Supersedable $true
        $fix = Get-FmToolModuleInstallCommand -Name $requirement.Name -MinimumVersion $requirement.MinimumVersion
        switch ($classification) {
            'missing' {
                $checks += New-FmInstallCheck -Name $name -Status 'warn' -Detail "not installed - $($requirement.Why)" -Fix $fix
            }
            { $_ -in 'unsupported', 'superseded' } {
                $checks += New-FmInstallCheck -Name $name -Status 'warn' `
                    -Detail "$($status.Version) is installed; this repo requires at least $($requirement.MinimumVersion) ($($requirement.MinimumSource))" `
                    -Fix $fix
            }
            default {
                $checks += New-FmInstallCheck -Name $name -Status 'ok' -Detail "$($status.Version) - $($status.Path)"
            }
        }
    }
    $checks
}
