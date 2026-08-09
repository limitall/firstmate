# bin/fm-ensure-agents-md.ps1 - ensure a project worktree follows the
# agent-memory file convention.
#
# Twin: bin/fm-ensure-agents-md.sh
#
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# relative symlink to it for compatibility. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present, and refuses to clobber distinct real files or wrong symlinks.
# Where symlinks cannot be created at all, CLAUDE.md instead becomes a real file
# holding Claude Code's `@AGENTS.md` import directive. Both forms are recognized
# as an existing correct alias; see docs/windows.md.
#
# ---------------------------------------------------------------------------
# THE THREE RECOGNIZED ALIAS STATES ARE THE WHOLE CONTRACT
#
# A project's CLAUDE.md is exactly one of: a symlink resolving to AGENTS.md, the
# `@AGENTS.md` import FILE, or something else (which is a conflict). Both
# language twins must recognize all three, because a home is shared: a project
# repaired by the bash twin is read by this one and vice versa, and a twin that
# recognized only its own output would "repair" the other's correct work.
#
# THE SYMLINK PROBE IS A REAL PROBE IN BOTH WORLDS. `ln -s` reports success on a
# platform that only copies, so the bash twin creates a link and inspects it
# rather than trusting an exit status; New-Item -ItemType SymbolicLink throws
# outright without Developer Mode or elevation. Verified on the reference
# Windows 11 host: BOTH refuse (bash's copy is not a reparse point;
# New-Item raises UnauthorizedAccessException), so both write the import file and
# the two worlds agree. The probe is kept honest rather than hard-coded because
# the answer is a process privilege, not a property of this repo - a host with
# Developer Mode on will produce real symlinks here, which the bash twin already
# recognizes as a correct alias.
#
# ---------------------------------------------------------------------------
# LINE ENDINGS ARE PRESERVED, NOT NORMALIZED
#
# A project checked out with core.autocrlf=true has a CRLF AGENTS.md, and
# appending an LF-only section would leave a mixed-ending file that git then
# reports as wholly modified. So the injection detects the file's own convention
# and matches it, exactly as the bash twin does - which is why this script is one
# of the few places that deliberately does NOT go through Set-FmFileText's LF
# normalization for the file it appends to. Note the bash twin's own comment
# about `grep -q $'\r$'` being useless under MSYS (text-mode grep strips the CR
# before matching); the check here reads the bytes, so it has no such hazard.
#
# ---------------------------------------------------------------------------
# python3 IS KEPT
#
# The realpath comparison for a non-literal CLAUDE.md symlink target stays on
# python3, and is invoked with RELATIVE arguments from the project directory
# exactly as the bash twin does, so it works whether python3 is the MSYS build
# or a native Windows one - neither has to understand the other's path spelling.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCE FROM THE BASH ORACLE
#
#   MESSAGE PATHS ARE PRINTED IN MSYS/POSIX FORM (/f/proj/x), because the bash
#   twin prints what `pwd -P` gives it and both twins' output is read by the same
#   people and the same differential harness. Under a Windows temp root the two
#   spellings genuinely differ (bash says /tmp/..., this says
#   /c/Users/.../Temp/...) because MSYS's /tmp is a mount-table fiction; that is
#   a fixture artifact, not a behavior difference, and the differential suite
#   normalizes the fixture path on both sides rather than pretending otherwise.
#
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

# --- helpers -----------------------------------------------------------------

# The canonical self-governance wording this script owns. One array, one source,
# rendered with whichever end-of-line the target file already uses.
function Get-FmMaintenanceSectionText {
    param([Parameter(Mandatory, Position = 0)][string]$Eol)
    $lines = @(
        '## Maintaining this file'
        ''
        'Keep this file for knowledge useful to almost every future agent session in this project.'
        'Do not repeat what the codebase already shows; point to the authoritative file or command instead.'
        'Prefer rewriting or pruning existing entries over appending new ones.'
        'When updating this file, preserve this bar for all agents and keep entries concise.'
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in $lines) { [void]$sb.Append($line).Append($Eol) }
    return $sb.ToString()
}

# True when some line of the file ends with CR, i.e. the file uses CRLF endings.
# Reads bytes rather than asking a text-mode tool, for the reason the bash twin's
# own comment records. A final line with no terminator counts as a line, so a
# CRLF file whose last line is unterminated still reports CRLF.
function Test-FmFileUsesCrlf {
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $text = Get-FmFileText $Path
    if ($text -eq '') { return $false }
    $segments = @($text -split "`n")
    if ($segments.Length -gt 0 -and $segments[-1] -eq '') {
        $segments = $segments[0..($segments.Length - 2)]
    }
    foreach ($segment in $segments) {
        if ($segment.EndsWith("`r", [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# Idempotently append the canonical self-governance section when it is absent.
# Returns $true when it appended, $false when the section was already present, so
# the caller can report whether the file changed.
function Add-FmMaintenanceSection {
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $heading = '## Maintaining this file'
    foreach ($line in (Get-FmFileLines $Path)) {
        # The CR variant is matched explicitly: Get-FmFileLines splits on LF and
        # keeps the CR, and MSYS grep's text mode makes the bash twin's two
        # patterns collapse into this same one test.
        if ($line -ceq $heading -or $line -ceq ($heading + "`r")) { return $false }
    }

    $eol = if (Test-FmFileUsesCrlf $Path) { "`r`n" } else { "`n" }
    $separator = ''
    $native = ConvertTo-FmNativePath $Path
    $length = 0
    if ([System.IO.File]::Exists($native)) { $length = [System.IO.FileInfo]::new($native).Length }
    if ($length -gt 0) {
        # `[ -n "$(tail -c 1 ...)" ]`: command substitution strips a trailing LF,
        # so a file already ending in a newline needs ONE eol to open a blank
        # line, and one that does not needs two.
        $lastByte = [System.IO.File]::ReadAllBytes($native)[-1]
        $separator = if ($lastByte -eq 0x0A) { $eol } else { $eol + $eol }
    }

    $body = $separator + (Get-FmMaintenanceSectionText $eol)
    # Raw bytes, not Add-FmFileLine: that helper strips CR by contract, which is
    # exactly wrong for the CRLF-preserving append above.
    [System.IO.File]::AppendAllText($native, $body, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Write-FmSkeletonFile {
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $skeleton = @(
        '# Project agent memory'
        ''
        "This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code."
        ''
        '- Add durable project-specific notes here as they are discovered through real work.'
    ) -join "`n"
    Set-FmFileText -Path $Path -Text $skeleton
    $null = Add-FmMaintenanceSection $Path
}

# Probe whether a real symlink can actually be created here, once per run. See
# the header: the answer is a process privilege, so it is memoized, and it is
# probed rather than assumed because a Developer Mode host answers differently.
$script:FmSymlinkCapable = $null
function Test-FmSymlinkCapable {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Dir,
        [Parameter(Mandatory, Position = 1)][string]$Target
    )
    if ($null -ne $script:FmSymlinkCapable) { return $script:FmSymlinkCapable }
    $probe = Join-Path $Dir ".fm-symlink-probe.$PID"
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    $capable = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $probe -Value $Target -ErrorAction Stop
        $capable = Test-FmSymlink $probe
    } catch {
        # Without Developer Mode or elevation this throws UnauthorizedAccessException;
        # an unusable link is the same answer as a refused one.
        $capable = $false
    }
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    $script:FmSymlinkCapable = $capable
    return $capable
}

# Create the CLAUDE.md alias in whichever form this platform can sustain, and
# return the verb the reports use, so a message never claims a symlink that is
# not there.
function Add-FmClaudeAlias {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Dir,
        [Parameter(Mandatory, Position = 1)][string]$Agents,
        [Parameter(Mandatory, Position = 2)][string]$Claude
    )
    if (Test-FmSymlinkCapable $Dir $Agents) {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $Dir $Claude) -Value $Agents
        return 'symlinked'
    }
    Set-FmFileText -Path (Join-Path $Dir $Claude) -Text "@$Agents"
    return 'imported'
}

# The no-symlink equivalent of CLAUDE.md -> AGENTS.md: a regular file whose
# entire content is the `@AGENTS.md` import directive. The read is bounded at
# 4096 bytes because a real memory file is far longer than the directive, so a
# capped read that does not match is proof enough that this is content and not an
# alias. CR is stripped so a CRLF-mangled clone still classifies, and trailing
# LFs are dropped because the bash twin's `$(...)` does.
function Test-FmClaudeImportFile {
    param(
        [Parameter(Mandatory, Position = 0)][string]$ClaudePath,
        [Parameter(Mandatory, Position = 1)][string]$Agents
    )
    $native = ConvertTo-FmNativePath $ClaudePath
    if (-not [System.IO.File]::Exists($native)) { return $false }
    if (Test-FmSymlink $native) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($native)
    if ($bytes.Length -gt 4096) { $bytes = $bytes[0..4095] }
    $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
    $text = $text -replace "`r", ''
    $text = $text.TrimEnd("`n")
    return [string]::Equals($text, "@$Agents", [System.StringComparison]::Ordinal)
}

function Test-FmCorrectClaudeSymlink {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Dir,
        [Parameter(Mandatory, Position = 1)][string]$Agents,
        [Parameter(Mandatory, Position = 2)][string]$Claude
    )
    $claudePath = Join-Path $Dir $Claude
    if (-not (Test-FmSymlink $claudePath)) { return $false }
    $target = (Get-Item -LiteralPath $claudePath -Force).Target
    if ($null -ne $target) {
        if ([string]::Equals($target, $Agents, [System.StringComparison]::Ordinal) -or
            [string]::Equals($target, "./$Agents", [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir $Agents))) { return $false }
    if (-not (Test-FmCommand 'python3')) { return $false }
    # Relative arguments with the project directory as cwd: see the header note
    # on why python3 must never be handed a path spelling to interpret.
    $script = @(
        'import os'
        'import sys'
        'sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)'
    ) -join "`n"
    $result = Invoke-FmTool -FilePath 'python3' -Arguments @('-', $Claude, $Agents) `
        -WorkingDirectory $Dir -StdIn ($script + "`n")
    return $result.Ok
}

# --- main --------------------------------------------------------------------

Invoke-FmMain -UnexpectedCode 70 {
    $usage = 'usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]'
    $first = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    if ($first -ceq '-h' -or $first -ceq '--help') {
        Write-FmErr $usage
        Exit-FmScript 0
    }
    if ($fmArgv.Count -gt 1) {
        Write-FmErr $usage
        Exit-FmScript 1
    }

    # Not $input: that is a PowerShell automatic variable, and assigning to it
    # under Set-StrictMode is both a lint finding and a real hazard.
    $dirArg = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '.' }
    $dirArgNative = ConvertTo-FmNativePath $dirArg
    if (-not [System.IO.Directory]::Exists($dirArgNative)) {
        Write-FmErr "error: not a directory: $dirArg"
        Exit-FmScript 1
    }

    # `cd "$DIR" && pwd -P`: absolute AND physical, so a symlinked project path
    # reports the real location in every message below.
    $dirNative = [System.IO.Path]::GetFullPath($dirArgNative)
    $resolved = [System.IO.Directory]::ResolveLinkTarget($dirNative, $true)
    if ($null -ne $resolved) { $dirNative = $resolved.FullName }
    $dirNative = $dirNative.TrimEnd('\')
    $dir = ConvertTo-FmPosixPath $dirNative

    $agents = 'AGENTS.md'
    $claude = 'CLAUDE.md'
    $agentsPath = Join-Path $dirNative $agents
    $claudePath = Join-Path $dirNative $claude

    # Both alias forms leave the project already correct, so they report the same
    # way: the only thing left to do is the self-governance injection.
    $reportExistingAlias = {
        if (Add-FmMaintenanceSection $agentsPath) {
            Write-FmOut "updated: added ## Maintaining this file to AGENTS.md in $dir"
        } else {
            Write-FmOut "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $dir"
        }
        Exit-FmScript 0
    }

    # Refuse a case-variant real memory file (issue #389). On a case-insensitive
    # filesystem an existing lowercase agents.md satisfies every existence test
    # below, so the script would emit a CLAUDE.md symlink whose uppercase literal
    # target dangles once the tree is checked out on a case-sensitive filesystem.
    # Reading the real directory entries catches the mismatch on both filesystem
    # kinds; surface it for manual reconciliation instead of linking blindly.
    foreach ($entry in (Get-ChildItem -LiteralPath $dirNative -Force -ErrorAction SilentlyContinue)) {
        $entryName = $entry.Name
        if ($entryName.StartsWith('.', [System.StringComparison]::Ordinal)) { continue }
        if ([string]::Equals($entryName, $agents, [System.StringComparison]::Ordinal)) { continue }
        if ([string]::Equals($entryName, $agents, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-FmErr "conflict: memory file is named $entryName in $dir but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md links portably"
            Exit-FmScript 1
        }
    }

    if (Test-FmSymlink $agentsPath) {
        Write-FmErr "conflict: AGENTS.md is a symlink in $dir; expected AGENTS.md to be the real file"
        Exit-FmScript 1
    }
    $agentsIsFile = [System.IO.File]::Exists($agentsPath)
    $agentsExists = $agentsIsFile -or [System.IO.Directory]::Exists($agentsPath)
    if ($agentsExists -and -not $agentsIsFile) {
        Write-FmErr "conflict: AGENTS.md exists in $dir but is not a regular file"
        Exit-FmScript 1
    }

    $claudeIsSymlink = Test-FmSymlink $claudePath
    $claudeIsFile = [System.IO.File]::Exists($claudePath) -and -not $claudeIsSymlink
    $claudeExists = $claudeIsSymlink -or [System.IO.File]::Exists($claudePath) -or [System.IO.Directory]::Exists($claudePath)

    if ($agentsExists) {
        if ($claudeIsSymlink) {
            if (Test-FmCorrectClaudeSymlink $dirNative $agents $claude) { & $reportExistingAlias }
            Write-FmErr "conflict: CLAUDE.md is a symlink in $dir but does not point to AGENTS.md"
            Exit-FmScript 1
        }
        # An @AGENTS.md import file is this script's own no-symlink alias, not a
        # second real memory file, so it must be recognized before the
        # both-are-real conflict below.
        if (Test-FmClaudeImportFile $claudePath $agents) { & $reportExistingAlias }
        if (-not $claudeExists) {
            $injected = Add-FmMaintenanceSection $agentsPath
            $verb = Add-FmClaudeAlias $dirNative $agents $claude
            if ($injected) {
                Write-FmOut "updated: added ## Maintaining this file to AGENTS.md and $verb CLAUDE.md -> AGENTS.md in $dir"
            } else {
                Write-FmOut "${verb}: CLAUDE.md -> AGENTS.md in $dir"
            }
            Exit-FmScript 0
        }
        if ($claudeIsFile) {
            Write-FmErr "conflict: both AGENTS.md and CLAUDE.md are real files in $dir; reconcile them manually"
            Exit-FmScript 1
        }
        Write-FmErr "conflict: CLAUDE.md exists in $dir but is not a regular file or symlink"
        Exit-FmScript 1
    }

    if ($claudeIsSymlink) {
        if (Test-FmCorrectClaudeSymlink $dirNative $agents $claude) {
            Write-FmSkeletonFile $agentsPath
            Write-FmOut "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $dir"
            Exit-FmScript 0
        }
        Write-FmErr "conflict: CLAUDE.md is a symlink in $dir but AGENTS.md is missing and the link does not point to AGENTS.md"
        Exit-FmScript 1
    }

    # An @AGENTS.md import file is an alias, not content: promoting it would write
    # "@AGENTS.md" into AGENTS.md and leave the import pointing at itself. Fill in
    # the missing AGENTS.md and keep the alias, exactly as the symlink branch does.
    if (Test-FmClaudeImportFile $claudePath $agents) {
        Write-FmSkeletonFile $agentsPath
        Write-FmOut "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $dir"
        Exit-FmScript 0
    }

    if ($claudeExists) {
        if ($claudeIsFile) {
            [System.IO.File]::Move($claudePath, $agentsPath)
            $null = Add-FmMaintenanceSection $agentsPath
            $verb = Add-FmClaudeAlias $dirNative $agents $claude
            Write-FmOut "promoted: moved CLAUDE.md to AGENTS.md and $verb CLAUDE.md -> AGENTS.md in $dir"
            Exit-FmScript 0
        }
        Write-FmErr "conflict: CLAUDE.md exists in $dir but is not a regular file or symlink"
        Exit-FmScript 1
    }

    Write-FmSkeletonFile $agentsPath
    $null = Add-FmClaudeAlias $dirNative $agents $claude
    Write-FmOut "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $dir"
    Exit-FmScript 0
}
