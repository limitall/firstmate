# bin/fm-merge-local.ps1 - perform the approved local merge for a local-only ship
# task: fast-forward the project's default branch to the crewmate's fm/<id>
# branch.
#
# Twin: bin/fm-merge-local.sh
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# Usage: fm-merge-local.ps1 <task-id>
#
# ---------------------------------------------------------------------------
# THIS FILE IS A MERGE-AUTHORITY BOUNDARY, SO EVERY GUARD IS PORTED AS A GUARD
#
# Six refusals stand between an invocation and a write into a project checkout,
# and each one keeps its exact wording and its exit code 1, because a caller (and
# the captain reading the relay) distinguishes them by text:
#
#   1. no meta for the task            - nothing proves this id is a real task.
#   2. mode is not local-only          - PR tasks land through fm-pr-merge.
#   3. fm/<id> does not exist          - there is nothing to merge.
#   4. the default branch is unknown   - we would guess where to land it.
#   5. the checkout is off-default     - the fast-forward would land elsewhere.
#   6. the checkout is dirty           - someone's uncommitted work is in the way.
#   7. the branch has diverged         - REFUSED; the crewmate must rebase.
#
# Nothing here forces, stashes, resets, or discards, and no convenience path was
# added during the conversion. `git merge --ff-only` is the only state-changing
# command in the file.
#
# ---------------------------------------------------------------------------
# TWO MECHANICS WORTH NAMING
#
#   PATHS ARE READ FROM A DURABLE RECORD, SO THEY MAY BE MSYS-FORM. state/<id>.meta
#   is written by whichever world spawned the task, and the bash twins still write
#   `/f/...`. git.exe cannot resolve that, so every git call converts with
#   ConvertTo-FmNativePath - while every DIAGNOSTIC prints the raw recorded string,
#   exactly as the bash twin does, so the captain sees the path their records hold.
#
#   THE meta READS ARE `grep | cut`, NOT last-wins. The bash uses
#   `grep '^project=' | cut -d= -f2-`, which concatenates EVERY matching line.
#   Get-FmMetaValue is last-wins and would silently disagree on a malformed
#   duplicate-key record, so the grep semantics are reproduced literally here.
#
# ---------------------------------------------------------------------------
# ONE DECLARED DIVERGENCE
#
#   The missing-argument diagnostic. The bash uses `${1:?usage: ...}`, whose
#   message is emitted by BASH ITSELF and carries the shell's own prefix and the
#   source line number ("bin/fm-merge-local.sh: line 20: 1: usage: ..."). No
#   PowerShell construct produces that shape, and faking a bash line number would
#   be a lie. The twin therefore emits the same `usage: fm-merge-local.sh
#   <task-id>` text under this script's own prefix, with the SAME exit code 1.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force

# No param() block: the bash CLI takes one bare positional word, and a declared
# parameter would make PowerShell try to BIND a leading-dash argument instead of
# passing it through. See bin/fm-operational-input.ps1's header.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $fmRoot = $context.Root
    $stateDir = $context.State

    # `"$FM_ROOT/bin/fm-guard.sh" || true`: the guard warns, it never blocks.
    $null = Invoke-FmScript -Name 'fm-guard' -BinDir (Join-Path $fmRoot 'bin') -Stream

    if ($fmArgv.Count -lt 1 -or [string]::IsNullOrEmpty([string]$fmArgv[0])) {
        Write-FmLog 'usage: fm-merge-local.sh <task-id>'
        Exit-FmScript 1
    }
    $id = [string]$fmArgv[0]

    $meta = Join-Path $stateDir "$id.meta"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        Write-FmErr "error: no meta for task $id at $meta"
        Exit-FmScript 1
    }

    # `grep '^<key>=' "$META" | cut -d= -f2-` - EVERY matching line, joined by LF,
    # with `$( )`'s trailing-newline strip. Deliberately not the last-wins reader.
    function Get-GrepCutValue {
        param([string]$Path, [string]$Key)
        $prefix = "$Key="
        $values = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-FmFileLines $Path)) {
            if ($line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                $values.Add($line.Substring($line.IndexOf('=') + 1))
            }
        }
        return ([string]::Join("`n", $values)).TrimEnd("`n")
    }

    $proj = Get-GrepCutValue -Path $meta -Key 'project'
    $mode = Get-GrepCutValue -Path $meta -Key 'mode'

    if ($mode -cne 'local-only') {
        Write-FmErr ("error: task $id is mode=$mode, not local-only; merge PR tasks with " +
            'bin/fm-pr-merge.sh <id> <PR url> after approval')
        Exit-FmScript 1
    }

    # `git -C "$PROJ" ...`, with the recorded path converted for git.exe.
    function Invoke-ProjGit {
        param([string]$Directory, [string[]]$Arguments)
        return (Invoke-FmTool -FilePath 'git' -Arguments (@('-C', (ConvertTo-FmNativePath $Directory)) + $Arguments))
    }

    $branch = "fm/$id"
    $branchExists = Invoke-ProjGit -Directory $proj -Arguments @(
        'rev-parse', '--verify', '--quiet', "refs/heads/$branch")
    if (-not $branchExists.Ok) {
        Write-FmErr "error: branch $branch does not exist in $proj"
        Exit-FmScript 1
    }

    # The same origin/HEAD -> main -> master resolution the fast-forward library
    # owns; this script's bash twin carries a byte-identical private copy.
    $default = Get-FmFfDefaultBranch -Directory $proj
    if ([string]::IsNullOrEmpty($default)) {
        Write-FmErr ("error: cannot determine default branch for $proj; " +
            'expected origin/HEAD, main, or master')
        Exit-FmScript 1
    }

    # The project's main checkout must be on its default branch and clean, so the
    # fast-forward lands predictably (firstmate never writes here otherwise).
    $headResult = Invoke-ProjGit -Directory $proj -Arguments @('symbolic-ref', '--short', 'HEAD')
    $cur = ''
    if ($headResult.Ok) { $cur = $headResult.StdOut.TrimEnd("`n") }
    if ($cur -cne $default) {
        Write-FmErr ("error: $proj is on '$cur', expected default branch '$default'; " +
            'cannot merge safely')
        Exit-FmScript 1
    }

    $status = Invoke-ProjGit -Directory $proj -Arguments @('status', '--porcelain')
    $firstStatusLine = ''
    if (-not [string]::IsNullOrEmpty($status.StdOut)) {
        $firstStatusLine = @($status.StdOut -split "`n")[0]
    }
    if ($firstStatusLine -ne '') {
        Write-FmErr "error: $proj has a dirty working tree; refusing to merge into it"
        Exit-FmScript 1
    }

    # Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
    $ancestor = Invoke-ProjGit -Directory $proj -Arguments @(
        'merge-base', '--is-ancestor', $default, $branch)
    if (-not $ancestor.Ok) {
        Write-FmErr "REFUSED: $branch is not a fast-forward of $default (it has diverged)."
        Write-FmErr "Have the crewmate rebase $branch onto $default, then retry."
        Exit-FmScript 1
    }

    # From here `set -e` governs the bash: a git failure aborts with git's own
    # exit code and its own stderr, which is reproduced rather than absorbed.
    $beforeResult = Invoke-ProjGit -Directory $proj -Arguments @('rev-parse', '--short', $default)
    if (-not $beforeResult.Ok) {
        [Console]::Error.Write($beforeResult.StdErr)
        Exit-FmScript $beforeResult.ExitCode
    }
    $before = $beforeResult.StdOut.TrimEnd("`n")

    $merge = Invoke-ProjGit -Directory $proj -Arguments @('merge', '--ff-only', $branch)
    if (-not $merge.Ok) {
        # `>/dev/null` discards git's stdout; its stderr reaches the caller.
        [Console]::Error.Write($merge.StdErr)
        Exit-FmScript $merge.ExitCode
    }

    $afterResult = Invoke-ProjGit -Directory $proj -Arguments @('rev-parse', '--short', $default)
    if (-not $afterResult.Ok) {
        [Console]::Error.Write($afterResult.StdErr)
        Exit-FmScript $afterResult.ExitCode
    }
    $after = $afterResult.StdOut.TrimEnd("`n")

    Write-FmOut "merged $branch into local $default ($before -> $after) in $proj"
    Exit-FmScript 0
}
