#requires -Version 7.0
# FmAgentsMemory.ps1 - the project agent-memory file convention, ported from
# bin/fm-ensure-agents-md.sh.
#
# THE CONVENTION: AGENTS.md is the real project-intrinsic knowledge file, and
# CLAUDE.md carries the same content so a Claude session finds it under the name
# it looks for. This command creates a minimal AGENTS.md when neither file
# exists, promotes a real CLAUDE.md when it is the only file present, injects
# the canonical "## Maintaining this file" self-governance section idempotently,
# and REFUSES to clobber distinct real files or a wrong link. It is a worktree
# utility for crewmates, not a supervision script, so it does not call the guard.
#
# THE WINDOWS DIFFERENCE, AND WHY IT IS NOT A SYMLINK EVERYWHERE
#
# On Linux the second name is a relative symlink, and that is exactly what this
# port creates when it can. On Windows, creating a symlink needs Developer Mode
# or elevation - the design report MEASURED that creation failing on a stock
# runner - and a default `core.symlinks=false` git checkout materializes a
# committed symlink as a text file containing its target path, which silently
# breaks the very loading the convention exists to guarantee.
#
# So the port asks for the strongest link the host allows, in order:
#   symlink  - the Linux shape; one file, no drift, portable back to Linux.
#   hardlink - two names for ONE file on NTFS, no privilege needed. Content
#              cannot drift, because there is only one file.
#   copy     - last resort. Content CAN drift, so it is re-synced on every run;
#              Get-FmAgentsMirrorState below is what tells drift from a genuine
#              second memory file, and only it may license an overwrite.
# The kind that was actually created is always reported, because "symlinked" is
# a claim about the filesystem and a copy must never be described as one.

Set-StrictMode -Version Latest

$script:FmAgentsFileName = 'AGENTS.md'
$script:FmClaudeFileName = 'CLAUDE.md'

# The canonical self-governance wording. This file is its owner: the skeleton,
# a promoted CLAUDE.md, and any existing AGENTS.md that lacks it all get this
# exact text, so every project's bar reads the same.
$script:FmAgentsMaintenanceHeading = '## Maintaining this file'
$script:FmAgentsMaintenanceLines = @(
    '## Maintaining this file',
    '',
    'Keep this file for knowledge useful to almost every future agent session in this project.',
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.',
    'Prefer rewriting or pruning existing entries over appending new ones.',
    'When updating this file, preserve this bar for all agents and keep entries concise.'
)

$script:FmAgentsSkeletonLines = @(
    '# Project agent memory',
    '',
    "This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.",
    '',
    '- Add durable project-specific notes here as they are discovered through real work.'
)

# Add-FmAgentsMaintenanceSection: append the canonical section when it is
# absent. Idempotent; returns $true only when it actually appended, so a caller
# can report whether the file changed.
#
# The file's OWN line ending is preserved: a CRLF file stays CRLF. This is the
# one place in the port that deliberately writes CRLF, because this file belongs
# to the project being worked in, not to firstmate's LF-only state contract.
function Add-FmAgentsMaintenanceSection {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $text = if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::ReadAllText($Path) } else { '' }
    foreach ($line in ($text -split "`n")) {
        if (($line -replace "`r$", '') -eq $script:FmAgentsMaintenanceHeading) { return $false }
    }

    $eol = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $separator = ''
    if ($text.Length -gt 0) {
        $separator = if ($text.EndsWith("`n")) { $eol } else { "$eol$eol" }
    }
    $section = ($script:FmAgentsMaintenanceLines | ForEach-Object { "$_$eol" }) -join ''
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($Path, ($separator + $section), $encoding)
    $true
}

function Write-FmAgentsSkeleton {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Write-FmTextFileLf -Path $Path -Text (($script:FmAgentsSkeletonLines -join "`n") + "`n")
    $null = Add-FmAgentsMaintenanceSection -Path $Path
}

# Test-FmAgentsClaudeLink: does CLAUDE.md point at AGENTS.md? True only for a
# real symlink whose target IS this AGENTS.md - the literal 'AGENTS.md' and
# './AGENTS.md' targets, or any target that resolves to the same file.
function Test-FmAgentsClaudeLink {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudePath,
        [Parameter(Mandatory)][string]$AgentsPath
    )

    $item = Get-Item -LiteralPath $ClaudePath -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.LinkTarget) { return $false }
    $target = $item.LinkTarget
    if ($target -eq $script:FmAgentsFileName -or $target -eq "./$($script:FmAgentsFileName)") { return $true }
    if (-not (Test-Path -LiteralPath $AgentsPath)) { return $false }
    $resolvedLink = Resolve-FmPhysicalPath -Path $ClaudePath
    $resolvedAgents = Resolve-FmPhysicalPath -Path $AgentsPath
    if (-not $resolvedLink -or -not $resolvedAgents) { return $false }
    Test-FmPathEqual -Left $resolvedLink -Right $resolvedAgents
}

# Test-FmAgentsMirror: are these two REAL files byte-identical? That is what
# makes a hardlinked or copied CLAUDE.md a materialized link rather than a
# second, independent memory file - and therefore safe to re-sync instead of
# refusing over.
function Test-FmAgentsMirror {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentsPath,
        [Parameter(Mandatory)][string]$ClaudePath
    )

    if (-not (Test-Path -LiteralPath $AgentsPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) { return $false }
    $a = Get-Item -LiteralPath $AgentsPath -Force
    $c = Get-Item -LiteralPath $ClaudePath -Force
    if ($a.Length -ne $c.Length) { return $false }
    $ha = (Get-FileHash -LiteralPath $AgentsPath -Algorithm SHA256).Hash
    $hc = (Get-FileHash -LiteralPath $ClaudePath -Algorithm SHA256).Hash
    $ha -eq $hc
}

# Test-FmAgentsLinkCommitted: does the REPOSITORY holding this directory record
# CLAUDE.md as a symlink to AGENTS.md?
#
# THIS IS THE PROVENANCE ANSWER, and byte-identity is not one. Two real files
# that differ are ambiguous on disk: a mirror that has fallen behind and a second,
# independent memory file look exactly alike, which is why the ambiguous case is
# refused. But a repo that COMMITS CLAUDE.md as a symlink to AGENTS.md has already
# said which one it is - the content it tracks for that path is the string
# 'AGENTS.md', so no working-tree file there can be carrying knowledge of its own.
# Re-syncing it can lose nothing.
#
# The index, not the working tree, is what is read: on a core.symlinks=false
# Windows checkout the working tree is precisely where the declaration has been
# lost, and the index is where it survives. The declaration also survives
# --skip-worktree, which is what Protect-FmInstructionLink sets on this path and
# which is why a stale mirror never shows up in `git status`.
#
# Deliberately narrow: mode 120000, and a target of exactly 'AGENTS.md' or
# './AGENTS.md' - the two spellings this port and the Linux original write. A
# symlink committed to anything else is not this mirror and is left alone.
function Test-FmAgentsLinkCommitted {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudePath)

    $dir = Split-Path -Parent $ClaudePath
    if (-not $dir) { return $false }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }

    try {
        # A relative pathspec resolves against -C, so this names THIS directory's
        # CLAUDE.md even when the directory is deep inside the repo.
        $entry = @(& git -C $dir ls-files -s -- $script:FmClaudeFileName 2>$null)
        if ($LASTEXITCODE -ne 0 -or $entry.Count -eq 0) { return $false }
        # "<mode> <sha> <stage>\t<path>"
        $fields = ([string]$entry[0]) -split '\s+'
        if ($fields.Count -lt 2) { return $false }
        if ($fields[0] -ne '120000') { return $false }
        $target = (@(& git -C $dir cat-file -p $fields[1] 2>$null) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0) { return $false }
    } catch {
        return $false
    }
    $target -eq $script:FmAgentsFileName -or $target -eq "./$($script:FmAgentsFileName)"
}

# Test-FmAgentsLinkPlaceholder: is this CLAUDE.md a symlink that git checked out
# as ORDINARY TEXT?
#
# MEASURED on the captain's Windows 11 laptop: this repo tracks CLAUDE.md as a
# symlink to AGENTS.md, and a clone with core.symlinks=false - which is the
# default for a non-elevated Windows git - writes a 9-byte regular file whose
# entire content is the string "AGENTS.md". A Claude session started in that
# checkout therefore reads a CLAUDE.md consisting of one filename and comes up
# with no project instructions at all, silently.
#
# That is a link the host failed to materialize, not a second memory file, so it
# is recognised here rather than refused as a conflict. The test is deliberately
# narrow: one short line, no newline required, naming AGENTS.md and nothing else.
#
# WINDOWS-UNVERIFIED: the placeholder itself was MEASURED on the laptop (9 bytes,
# 'AGENTS.md', core.symlinks=false). What has not run on Windows is the REPAIR -
# New-FmAgentsClaudeLink replacing it, which on a non-elevated Windows session
# falls through symlink to hardlink to copy. Green on Linux; see
# docs/windows-e2e-evidence.md section 6.5.
function Test-FmAgentsLinkPlaceholder {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudePath)

    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $ClaudePath -Force
    # A real memory file is never this small; the placeholder is exactly the
    # link text. Bounding the length first keeps this from reading a large file.
    if ($item.Length -gt 260) { return $false }
    $text = ([System.IO.File]::ReadAllText($ClaudePath)).Trim()
    if (-not $text) { return $false }
    if ($text -match '[\r\n]') { return $false }
    $leaf = Split-Path -Leaf ($text -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    # Case-insensitive on Windows, exact elsewhere - the same rule Test-FmPathEqual
    # applies, asked of a filename.
    if ($IsWindows) { return $leaf -ieq $script:FmAgentsFileName }
    return $leaf -ceq $script:FmAgentsFileName
}

# Get-FmAgentsMirrorState: the ONE place that decides what a CLAUDE.md beside an
# AGENTS.md actually is. The repair, the doctor's check and the surface report all
# read it, because a classifier that disagrees with the repairer is the exact
# failure this function was added for: the doctor saying "run setup" while setup
# refuses, or the doctor saying "reconcile by hand" over something setup would
# gladly fix.
#
#   missing      no CLAUDE.md at all.
#   link         a real symlink resolving to AGENTS.md. Cannot drift.
#   placeholder  the text git leaves for a symlink it could not create.
#   mirror       a real file carrying the same bytes. A materialized link, current.
#   stale        a real file with DIFFERENT bytes, at a path the repo commits as a
#                symlink to AGENTS.md. A materialized link that has fallen behind.
#   conflict     a real file with different bytes and nothing declaring it a link.
#                Genuinely ambiguous, so it is the captain's to reconcile.
#
# 'stale' is the state this port was missing, and its absence was not neutral. A
# mirror that falls behind its contract is not merely untidy: a session reads the
# OLD operating contract under the name it looks for, behaves to it, and nothing
# says so - while --skip-worktree, which is what keeps git from restoring over the
# materialized link in the first place, also keeps the drift out of `git status`.
# Classified as 'conflict' it was reported as a thing that must not be repaired,
# so nothing repaired it. It is the file-level twin of the skills tree's
# 'drifted', which setup has always re-synced (Get-FmClaudeSkillsLinkState).
function Get-FmAgentsMirrorState {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentsPath,
        [Parameter(Mandatory)][string]$ClaudePath
    )

    if (-not (Test-Path -LiteralPath $ClaudePath -PathType Leaf)) { return 'missing' }
    if (Test-FmAgentsLinkPlaceholder -ClaudePath $ClaudePath) { return 'placeholder' }
    if (Test-FmAgentsClaudeLink -ClaudePath $ClaudePath -AgentsPath $AgentsPath) { return 'link' }
    if (Test-FmAgentsMirror -AgentsPath $AgentsPath -ClaudePath $ClaudePath) { return 'mirror' }
    # 'stale' means BEHIND the contract, so it presupposes one. With no AGENTS.md
    # there is nothing to be behind and nothing to re-sync from; that is the
    # contract check's finding, not this one's, and answering 'stale' here would
    # send a caller to read a file that is not there.
    if ((Test-Path -LiteralPath $AgentsPath -PathType Leaf) -and
        (Test-FmAgentsLinkCommitted -ClaudePath $ClaudePath)) { return 'stale' }
    'conflict'
}

# New-FmAgentsClaudeLink: create CLAUDE.md as the strongest link to AGENTS.md
# this host allows. Returns the kind that was created ('symlink', 'hardlink' or
# 'copy'), so no caller can describe a copy as a link.
function New-FmAgentsClaudeLink {
    # No ShouldProcess: the public cmdlet gates this, and this helper must
    # RETURN the kind of link it created so the caller can report it honestly -
    # a preview-shaped $null return would produce a wrong message.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'No ShouldProcess: the public cmdlet gates this, and this helper must RETURN the kind of link it created so the caller can report it honestly - a preview-shaped $null return would produce a wrong message.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('Auto', 'Symlink', 'HardLink', 'Copy')][string]$Strategy = 'Auto'
    )

    $claudePath = Join-Path $Directory $script:FmClaudeFileName
    $agentsPath = Join-Path $Directory $script:FmAgentsFileName

    $order = switch ($Strategy) {
        'Symlink' { @('symlink') }
        'HardLink' { @('hardlink') }
        'Copy' { @('copy') }
        default { @('symlink', 'hardlink', 'copy') }
    }

    foreach ($kind in $order) {
        try {
            switch ($kind) {
                'symlink' {
                    # A RELATIVE target, so the pair survives being moved,
                    # copied, or checked out under a different root.
                    $null = New-Item -ItemType SymbolicLink -Path $claudePath -Value $script:FmAgentsFileName -ErrorAction Stop
                }
                'hardlink' {
                    $null = New-Item -ItemType HardLink -Path $claudePath -Value $agentsPath -ErrorAction Stop
                }
                'copy' {
                    Copy-Item -LiteralPath $agentsPath -Destination $claudePath -ErrorAction Stop
                }
            }
            return $kind
        } catch {
            continue
        }
    }
    throw "error: could not create $claudePath as a link, hardlink, or copy of $script:FmAgentsFileName in $Directory"
}

# The verb used when reporting a created link. Only a real symlink is called
# "symlinked".
function Get-FmAgentsLinkVerb {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'symlink' { 'symlinked' }
        'hardlink' { 'hardlinked' }
        default { 'copied' }
    }
}

# Test-FmAgentsCaseVariant: is there a case-variant real memory file, such as a
# lowercase agents.md, that is not exactly AGENTS.md?
#
# On a case-insensitive filesystem an existing agents.md satisfies every
# "does AGENTS.md exist" test, so the command would emit a CLAUDE.md link whose
# uppercase literal target dangles the moment the tree is checked out on a
# case-sensitive filesystem. Reading the real directory entries catches the
# mismatch on both filesystem kinds; the caller surfaces it for manual
# reconciliation instead of linking blindly.
function Test-FmAgentsCaseVariant {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        if ($entry.Name -ceq $script:FmAgentsFileName) { continue }
        if ($entry.Name -match '(?i)^agents\.md$') { return $entry.Name }
    }
    ''
}
