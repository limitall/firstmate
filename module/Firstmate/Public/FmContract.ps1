#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Report the instruction surface: the operating contract and the skills.

.DESCRIPTION
    Answers "is there a first mate here", which is the one question no other
    command in this port can answer. Every fm-*.ps1 can work perfectly in a
    checkout whose AGENTS.md never loaded and whose skills tree is a text file
    git left behind - the commands do not care, and the only symptom is a
    session that does not behave like firstmate.

    Returns the composed surface rather than a verdict, so a caller can print
    it, check it, or act on one part of it:

      ContractPath / MirrorPath   AGENTS.md and CLAUDE.md
      ContractPresent             the file exists AND carries the operating
                                  contract, not merely some markdown
      MirrorState                 link | mirror | placeholder | conflict | missing
      SkillRoot / ClaudeSkillRoot .agents/skills and .claude/skills
      Skills                      one record per skill: name, description,
                                  whether the captain can invoke it, and the
                                  reason it would not load if there is one
      ClaudeSkillsState           symlink | materialized | placeholder |
                                  drifted | missing
      Healthy                     every part of the surface is loadable
      Lines                       the same thing, formatted for a human

    Read-only. Set-FmClaudeSkillsLink is the repair.

.PARAMETER RepoRoot
    The checkout to report on. Defaults to the one this module was loaded from.

.EXAMPLE
    (Get-FmInstructionSurface).Skills | Where-Object Problem

.EXAMPLE
    (Get-FmInstructionSurface).Lines
#>
function Get-FmInstructionSurface {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RepoRoot = '')

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }

    $contract = Get-FmContractPath -RepoRoot $RepoRoot
    $mirror = Get-FmContractMirrorPath -RepoRoot $RepoRoot
    $skillRoot = Get-FmSkillRootPath -RepoRoot $RepoRoot
    $claudeSkillRoot = Get-FmClaudeSkillRootPath -RepoRoot $RepoRoot

    $contractPresent = $false
    if (Test-Path -LiteralPath $contract -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($contract)
        $contractPresent = ($text -like "*$script:FmContractIdentityMarker*") -and
            ($text.Length -ge $script:FmContractMinimumBytes)
    }

    # The mirror's states, in the same vocabulary the doctor prints. 'conflict'
    # is deliberately distinct from 'placeholder': one is a link the host failed
    # to make and is repaired, the other is two real files and is the captain's.
    $mirrorState = 'missing'
    if (Test-Path -LiteralPath $mirror -PathType Leaf) {
        if (Test-FmAgentsLinkPlaceholder -ClaudePath $mirror) { $mirrorState = 'placeholder' }
        elseif (Test-FmAgentsClaudeLink -ClaudePath $mirror -AgentsPath $contract) { $mirrorState = 'link' }
        elseif (Test-FmAgentsMirror -AgentsPath $contract -ClaudePath $mirror) { $mirrorState = 'mirror' }
        else { $mirrorState = 'conflict' }
    }

    $skills = @(Get-FmSkillDefinition -RepoRoot $RepoRoot)
    $claudeSkillsState = Get-FmClaudeSkillsLinkState -RepoRoot $RepoRoot
    $broken = @($skills | Where-Object { $_.Problem })

    $healthy = $contractPresent -and
        ($mirrorState -in @('link', 'mirror')) -and
        ($skills.Count -gt 0) -and
        ($broken.Count -eq 0) -and
        ($claudeSkillsState -in @('symlink', 'materialized'))

    $lines = @(
        "instruction surface: $RepoRoot"
        ''
        "  operating contract  $(if ($contractPresent) { 'present' } else { 'NOT LOADABLE' }) - $contract"
        "  for Claude          $mirrorState - $mirror"
        "  skills              $($skills.Count) - $skillRoot"
        "  for Claude          $claudeSkillsState - $claudeSkillRoot"
        ''
    )
    foreach ($skill in $skills) {
        $mark = if ($skill.Problem) { '!' } elseif ($skill.UserInvocable) { '/' } else { ' ' }
        # The description IS the trigger the model matches on, so a truncated
        # one is still the useful thing to show; the name alone is not.
        $summary = $skill.Description
        if ($summary.Length -gt 100) { $summary = $summary.Substring(0, 97) + '...' }
        if ($skill.Problem) { $summary = "WILL NOT LOAD: $($skill.Problem)" }
        $lines += ("  $mark " + $skill.Name.PadRight(28) + $summary)
    }

    [pscustomobject]@{
        RepoRoot          = $RepoRoot
        ContractPath      = $contract
        MirrorPath        = $mirror
        ContractPresent   = $contractPresent
        MirrorState       = $mirrorState
        SkillRoot         = $skillRoot
        ClaudeSkillRoot   = $claudeSkillRoot
        Skills            = $skills
        ClaudeSkillsState = $claudeSkillsState
        Healthy           = $healthy
        Lines             = $lines
    }
}

<#
.SYNOPSIS
    Make .claude/skills reach .agents/skills, whatever this host allows.

.DESCRIPTION
    The repair for the second of this repo's two committed symlinks. A Windows
    clone with core.symlinks=false - the default - writes a small text file
    containing the target path instead of a link, and the result is a checkout
    where every command works and a session loads zero skills.

    Idempotent and converging: a link or junction that already resolves is left
    alone and reported 'already'; a COPY is re-synced on every run, because a
    copy is the one shape that can fall behind the real tree.

    Asks for the strongest link this host allows, in order: symlink (the
    committed shape, needs Developer Mode or elevation on Windows), directory
    junction (needs no privilege on NTFS, and has no file-link equivalent -
    which is why this ladder differs from the AGENTS.md/CLAUDE.md one), then a
    copy. The kind actually created is always reported, because "symlinked" is a
    claim about the filesystem and a copy must never be described as one.

.PARAMETER RepoRoot
    The checkout to repair. Defaults to the one this module was loaded from.

.PARAMETER Strategy
    Force one rung of the ladder instead of taking the strongest available.
    Auto (the default) is what setup uses; the others exist so the suite can
    prove each rung independently of what the host running it happens to allow.

.EXAMPLE
    Set-FmClaudeSkillsLink
#>
function Set-FmClaudeSkillsLink {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$RepoRoot = '',
        [ValidateSet('Auto', 'Symlink', 'Junction', 'Copy')][string]$Strategy = 'Auto'
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    $link = Get-FmClaudeSkillRootPath -RepoRoot $RepoRoot
    $real = Get-FmSkillRootPath -RepoRoot $RepoRoot

    if (-not (Test-Path -LiteralPath $real -PathType Container)) {
        # Nothing to link to. Reported rather than thrown, because setup calls
        # this and a checkout with no skills tree is already being reported by
        # the doctor's own 'skills' check - a second exception adds nothing.
        return [pscustomobject]@{
            Action = 'skipped'
            Kind   = ''
            Detail = "NOT RUN: there is no skills tree at '$real' to link to"
        }
    }

    $state = Get-FmClaudeSkillsLinkState -RepoRoot $RepoRoot
    if ($state -eq 'symlink') {
        return [pscustomobject]@{ Action = 'already'; Kind = 'symlink'; Detail = "$link -> $real" }
    }
    # A materialized copy is only 'already' when Auto would not upgrade it, and
    # it is re-synced rather than trusted: Get-FmClaudeSkillsLinkState proved it
    # carries every skill, but not that each file's CONTENT is current.
    if ($state -eq 'materialized' -and $Strategy -eq 'Copy') {
        if (-not $PSCmdlet.ShouldProcess($link, 're-sync the skills copy')) {
            return [pscustomobject]@{ Action = 'skipped'; Kind = ''; Detail = 'WhatIf' }
        }
        $kind = New-FmClaudeSkillsLink -RepoRoot $RepoRoot -Strategy 'Copy'
        return [pscustomobject]@{ Action = 'updated'; Kind = $kind; Detail = "$link is a re-synced copy of $real" }
    }
    if ($state -eq 'materialized') {
        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkTarget) {
            return [pscustomobject]@{ Action = 'already'; Kind = 'junction'; Detail = "$link -> $real" }
        }
        if (-not $PSCmdlet.ShouldProcess($link, 're-sync the skills copy')) {
            return [pscustomobject]@{ Action = 'skipped'; Kind = ''; Detail = 'WhatIf' }
        }
        $kind = New-FmClaudeSkillsLink -RepoRoot $RepoRoot -Strategy $Strategy
        return [pscustomobject]@{ Action = 'updated'; Kind = $kind; Detail = "$link is a re-synced copy of $real" }
    }

    $existed = Test-Path -LiteralPath $link
    if (-not $PSCmdlet.ShouldProcess($link, "link the skills tree at $real")) {
        return [pscustomobject]@{ Action = 'skipped'; Kind = ''; Detail = 'WhatIf' }
    }
    $kind = New-FmClaudeSkillsLink -RepoRoot $RepoRoot -Strategy $Strategy
    $verb = switch ($kind) { 'symlink' { 'symlinked' } 'junction' { 'junctioned' } default { 'copied' } }
    [pscustomobject]@{
        Action = if ($existed) { 'updated' } else { 'created' }
        Kind   = $kind
        Detail = "$link $verb to $real"
    }
}
