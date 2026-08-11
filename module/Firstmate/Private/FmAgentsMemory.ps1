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
#   copy     - last resort. Content CAN drift, so it is re-synced on every run
#              and the drift is what the mirror check below looks for.
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

# New-FmAgentsClaudeLink: create CLAUDE.md as the strongest link to AGENTS.md
# this host allows. Returns the kind that was created ('symlink', 'hardlink' or
# 'copy'), so no caller can describe a copy as a link.
function New-FmAgentsClaudeLink {
    # No ShouldProcess: the public cmdlet gates this, and this helper must
    # RETURN the kind of link it created so the caller can report it honestly -
    # a preview-shaped $null return would produce a wrong message.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
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
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        if ($entry.Name -ceq $script:FmAgentsFileName) { continue }
        if ($entry.Name -match '(?i)^agents\.md$') { return $entry.Name }
    }
    ''
}
