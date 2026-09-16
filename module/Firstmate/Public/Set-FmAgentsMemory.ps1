#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Ensure a project worktree follows the agent-memory file convention.

.DESCRIPTION
The PowerShell port of bin/fm-ensure-agents-md.sh.

AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md carries the
same content under the name a Claude session looks for. This command:

  - creates a minimal AGENTS.md skeleton when neither file exists,
  - promotes a real CLAUDE.md to AGENTS.md when it is the only file present,
  - injects the canonical "## Maintaining this file" section idempotently into
    created skeletons, promoted files, and any existing AGENTS.md that lacks it,
  - refreshes a CLAUDE.md mirror that has fallen behind AGENTS.md, where the
    repository commits that path as a symlink to AGENTS.md and therefore says
    the mirror carries no knowledge of its own,
  - and REFUSES rather than clobbering: two distinct real files, a CLAUDE.md
    link that points elsewhere, an AGENTS.md that is itself a link or not a
    regular file, or a case-variant memory file whose link target would dangle
    on a case-sensitive filesystem.

Private/FmAgentsMemory.ps1 documents why the second name is a symlink where the
host allows one and a hardlink or copy where it does not, and why the kind
created is always reported honestly.

Every refusal throws with a "conflict: ..." message, which the entry point maps
to exit 1.

.PARAMETER Path
The repository or worktree directory. Defaults to the current directory.

.EXAMPLE
Set-FmAgentsMemory -Path .
#>
function Set-FmAgentsMemory {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Path = '.',
        [ValidateSet('Auto', 'Symlink', 'HardLink', 'Copy')][string]$LinkStrategy = 'Auto'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "error: not a directory: $Path"
    }
    $dir = Resolve-FmPhysicalPath -Path $Path
    $agents = Join-Path $dir 'AGENTS.md'
    $claude = Join-Path $dir 'CLAUDE.md'

    $variant = Test-FmAgentsCaseVariant -Directory $dir
    if ($variant) {
        throw ("conflict: memory file is named $variant in $dir but the convention is AGENTS.md; " +
            'rename it to AGENTS.md so CLAUDE.md links portably')
    }

    $agentsItem = Get-Item -LiteralPath $agents -Force -ErrorAction SilentlyContinue
    if ($agentsItem -and $agentsItem.LinkTarget) {
        throw "conflict: AGENTS.md is a symlink in $dir; expected AGENTS.md to be the real file"
    }
    if ($agentsItem -and -not ($agentsItem -is [System.IO.FileInfo])) {
        throw "conflict: AGENTS.md exists in $dir but is not a regular file"
    }

    $claudeItem = Get-Item -LiteralPath $claude -Force -ErrorAction SilentlyContinue
    $claudeIsLink = [bool]($claudeItem -and $claudeItem.LinkTarget)
    $claudeIsFile = [bool]($claudeItem -and -not $claudeItem.LinkTarget -and $claudeItem -is [System.IO.FileInfo])

    $report = {
        param($Action, $Message)
        [pscustomobject]@{ Action = $Action; Directory = $dir; Message = $Message }
    }

    if ($agentsItem) {
        if ($claudeIsLink) {
            if (-not (Test-FmAgentsClaudeLink -ClaudePath $claude -AgentsPath $agents)) {
                throw "conflict: CLAUDE.md is a symlink in $dir but does not point to AGENTS.md"
            }
            if (-not $PSCmdlet.ShouldProcess($dir, 'ensure the AGENTS.md maintenance section')) { return $null }
            if (Add-FmAgentsMaintenanceSection -Path $agents) {
                return & $report 'updated' "updated: added ## Maintaining this file to AGENTS.md in $dir"
            }
            return & $report 'unchanged' "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $dir"
        }

        if (-not $claudeItem) {
            if (-not $PSCmdlet.ShouldProcess($dir, 'link CLAUDE.md to AGENTS.md')) { return $null }
            $injected = Add-FmAgentsMaintenanceSection -Path $agents
            $kind = New-FmAgentsClaudeLink -Directory $dir -Strategy $LinkStrategy
            $verb = Get-FmAgentsLinkVerb -Kind $kind
            if ($injected) {
                return & $report 'updated' ("updated: added ## Maintaining this file to AGENTS.md and " +
                    "$verb CLAUDE.md -> AGENTS.md in $dir")
            }
            return & $report $verb "$verb`: CLAUDE.md -> AGENTS.md in $dir"
        }

        if ($claudeIsFile) {
            # Get-FmAgentsMirrorState owns what a real CLAUDE.md beside AGENTS.md
            # IS, and the doctor reads the same function - so what setup repairs
            # and what the doctor reports as repairable can never disagree.
            switch (Get-FmAgentsMirrorState -AgentsPath $agents -ClaudePath $claude) {
                'placeholder' {
                    # A symlink git checked out as ordinary text because
                    # core.symlinks=false - the default on Windows. It is a link
                    # this host failed to materialize, not a second memory file,
                    # and leaving it means a Claude session reads a one-line file
                    # naming AGENTS.md and gets no instructions at all.
                    if (-not $PSCmdlet.ShouldProcess($dir, 'materialize the CLAUDE.md link git left as text')) { return $null }
                    $null = Add-FmAgentsMaintenanceSection -Path $agents
                    Remove-Item -LiteralPath $claude -Force
                    $kind = New-FmAgentsClaudeLink -Directory $dir -Strategy $LinkStrategy
                    $verb = Get-FmAgentsLinkVerb -Kind $kind
                    return & $report $verb ("$verb`: CLAUDE.md -> AGENTS.md in $dir " +
                        '(it was a symlink git checked out as text)')
                }
                'stale' {
                    # A materialized link that has fallen behind its own AGENTS.md,
                    # which is EITHER fallback rung after a rebase replaced the
                    # contract under it - section 63.1 measured both. The repo
                    # commits this path as a symlink to AGENTS.md, so the file here
                    # carries no knowledge of its own and re-syncing loses nothing.
                    # Left alone it is worse than a missing mirror: the session
                    # reads an OLD contract under the name it looks for and says
                    # nothing. The whole ladder is re-run rather than the bytes
                    # copied, so a host that can now manage a stronger rung gets
                    # one and stops drifting.
                    if (-not $PSCmdlet.ShouldProcess($dir, 'refresh the CLAUDE.md mirror that has fallen behind AGENTS.md')) { return $null }
                    # Both sizes, not a signed difference: the drift is usually a
                    # shorter mirror but a deletion makes it longer, and "N bytes
                    # behind" would then be a negative number or a wrong word.
                    $was = (Get-Item -LiteralPath $claude -Force).Length
                    $now = (Get-Item -LiteralPath $agents -Force).Length
                    $null = Add-FmAgentsMaintenanceSection -Path $agents
                    Remove-Item -LiteralPath $claude -Force
                    $kind = New-FmAgentsClaudeLink -Directory $dir -Strategy $LinkStrategy
                    $verb = Get-FmAgentsLinkVerb -Kind $kind
                    return & $report 'updated' ("updated: $verb CLAUDE.md -> AGENTS.md in $dir " +
                        "(the mirror had drifted: $was bytes against AGENTS.md's $now)")
                }
                'mirror' {
                    # Byte-identical, so a MATERIALIZED link - the hardlink or copy
                    # this port falls back to where symlinks are unavailable - and
                    # current. Re-syncing it loses nothing; refusing over it would
                    # make the command permanently unusable on such a host.
                    # MEASURED, and it is why this branch is the NARROW one: BOTH
                    # fallback rungs drift, and not occasionally. Git does not write
                    # through a path, it replaces it, so a rebase that touches
                    # AGENTS.md leaves a hardlinked CLAUDE.md behind exactly as it
                    # leaves a copied one - docs/windows-e2e-evidence.md section 63.1.
                    # A mirror that has drifted therefore never arrives here; it is
                    # 'stale' above, and that is the state this command repairs.
                    if (-not $IsWindows -and -not (Test-FmAgentsLinkCommitted -ClaudePath $claude)) {
                        # On a host that can always symlink, two byte-identical real
                        # files are not a rung this port would have produced, so the
                        # SHAPE alone does not license an overwrite there. A commit
                        # declaring the path a link does, on either platform - and it
                        # has to, or this state would be refused on Linux while the
                        # drifted one right below it is repaired, which is the worse
                        # state getting the better treatment.
                        throw "conflict: both AGENTS.md and CLAUDE.md are real files in $dir; reconcile them manually"
                    }
                    if (-not $PSCmdlet.ShouldProcess($dir, 'ensure the AGENTS.md maintenance section')) { return $null }
                    if (Add-FmAgentsMaintenanceSection -Path $agents) {
                        Copy-Item -LiteralPath $agents -Destination $claude -Force
                        return & $report 'updated' ("updated: added ## Maintaining this file to AGENTS.md and " +
                            "re-synced the CLAUDE.md mirror in $dir")
                    }
                    return & $report 'unchanged' "unchanged: AGENTS.md with a CLAUDE.md mirror of it in $dir"
                }
            }
            throw "conflict: both AGENTS.md and CLAUDE.md are real files in $dir; reconcile them manually"
        }
        throw "conflict: CLAUDE.md exists in $dir but is not a regular file or symlink"
    }

    if ($claudeIsLink) {
        if (-not (Test-FmAgentsClaudeLink -ClaudePath $claude -AgentsPath $agents)) {
            throw ("conflict: CLAUDE.md is a symlink in $dir but AGENTS.md is missing and the link does not " +
                'point to AGENTS.md')
        }
        if (-not $PSCmdlet.ShouldProcess($dir, 'create AGENTS.md')) { return $null }
        Write-FmAgentsSkeleton -Path $agents
        return & $report 'created' "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $dir"
    }

    if ($claudeItem) {
        if (-not $claudeIsFile) {
            throw "conflict: CLAUDE.md exists in $dir but is not a regular file or symlink"
        }
        if (-not $PSCmdlet.ShouldProcess($dir, 'promote CLAUDE.md to AGENTS.md')) { return $null }
        Move-Item -LiteralPath $claude -Destination $agents
        $null = Add-FmAgentsMaintenanceSection -Path $agents
        $kind = New-FmAgentsClaudeLink -Directory $dir -Strategy $LinkStrategy
        $verb = Get-FmAgentsLinkVerb -Kind $kind
        return & $report 'promoted' "promoted: moved CLAUDE.md to AGENTS.md and $verb CLAUDE.md -> AGENTS.md in $dir"
    }

    if (-not $PSCmdlet.ShouldProcess($dir, 'create AGENTS.md and link CLAUDE.md to it')) { return $null }
    Write-FmAgentsSkeleton -Path $agents
    $kind = New-FmAgentsClaudeLink -Directory $dir -Strategy $LinkStrategy
    $verb = Get-FmAgentsLinkVerb -Kind $kind
    if ($kind -eq 'symlink') {
        return & $report 'created' "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $dir"
    }
    & $report 'created' "created: AGENTS.md and $verb CLAUDE.md -> AGENTS.md in $dir"
}
