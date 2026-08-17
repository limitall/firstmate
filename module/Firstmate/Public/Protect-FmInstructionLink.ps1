#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Stop `git checkout` emptying the skills tree through the link that points at
    it.

.DESCRIPTION
    THE TRAP, REPRODUCED. This repo tracks `.claude/skills` as a symlink to
    `.agents/skills`, and a Windows clone materializes it as a junction because
    it cannot make a symlink without elevation. Git sees the junction as a
    modified file and, when told to restore it, deletes the existing entry first
    - which on Windows recurses THROUGH the junction and empties the target:

        before  git checkout -- .claude   ->  1 skill
        after                             ->  0 skills

    That is not a hypothetical. It cost the skills tree three times in one
    session, each time from a command that reads as an ordinary file restore.
    `git restore` and `git checkout -- .` behave the same way.

    THE FIX IS STRUCTURAL, not a warning to remember. `--skip-worktree` tells git
    the working copy of a path is deliberately different and to leave it alone.
    Measured against all four dangerous forms - `git checkout -- <dir>`,
    `git checkout -- <path>`, `git checkout -- .`, and `git restore .` - the
    skills survive every one and the link stays intact.

    It also stops the pair reporting as permanently modified, which is worth
    having on its own: a checkout that always looks dirty trains the reader to
    ignore `git status`, and that is how a real change gets committed by
    accident.

    CLAUDE.md gets the same treatment for the same reason: it is the other
    committed symlink, materialized here as a hardlink.

.PARAMETER RepoRoot
    The checkout to protect.

.OUTPUTS
    A record naming what was protected and what could not be.

.EXAMPLE
    Protect-FmInstructionLink -RepoRoot C:\Users\me\firstmate-win
#>
function Protect-FmInstructionLink {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $result = [pscustomobject]@{
        Action    = 'skipped'
        Protected = @()
        Detail    = ''
    }

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        $result.Detail = 'not a git checkout, so there is nothing for git to restore over'
        return $result
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $result.Detail = 'git is not available'
        return $result
    }

    # Only the two committed symlinks this port materializes. Marking anything
    # else skip-worktree would hide real edits, which is the opposite of what
    # this is for.
    $paths = @('.claude/skills', 'CLAUDE.md')
    $done = @()
    $failed = @()

    foreach ($p in $paths) {
        $full = Join-Path $RepoRoot ($p -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full)) { continue }

        # Tracked-ness is checked first: skip-worktree on an untracked path is an
        # error, and on a path git does not know about it would mean nothing.
        $null = & git -C $RepoRoot ls-files --error-unmatch $p 2>&1
        if ($LASTEXITCODE -ne 0) { continue }

        if (-not $PSCmdlet.ShouldProcess($p, 'protect from git restore')) { continue }

        $null = & git -C $RepoRoot update-index --skip-worktree $p 2>&1
        if ($LASTEXITCODE -eq 0) { $done += $p } else { $failed += $p }
    }

    $result.Protected = $done
    if ($done.Count -and -not $failed.Count) {
        $result.Action = 'updated'
        $result.Detail = "git will no longer restore over $($done -join ' or ') - see Protect-FmInstructionLink for why that matters"
    } elseif ($failed.Count) {
        $result.Action = 'skipped'
        $result.Detail = "could not protect $($failed -join ', '); a git restore there can still empty the skills tree"
    } else {
        $result.Detail = 'neither link is tracked here, so git has nothing to restore over'
    }
    $result
}
