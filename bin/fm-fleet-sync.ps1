#requires -Version 7.0
<#
.SYNOPSIS
fm-fleet-sync.ps1 - refresh this home's project clones.

.DESCRIPTION
Port of bin/fm-fleet-sync.sh. Fast-forwards each checked-out local default
branch to origin/<default> when that is safe, and prunes local branches whose
upstream tracking branch is gone and that no worktree still needs.

Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
no unique commits and whose default branch is free to check out is re-attached
and then fast-forwarded ("recovered:"). Every other off-default state - a
non-default named branch, a detached HEAD with unique commits, a dirty tree, or
a diverged default - may hold real work, so it is left untouched and reported as
a quantified "STUCK: ... - needs attention" line. Nothing is ever forced,
stashed, or discarded.

Still skips (benignly) local-only/no-origin projects, missing remotes and
branches, and fetch failures. Set FM_FLEET_PRUNE=0 to disable pruning.

The single-project form accepts either a path (absolute, or relative to the
caller's cwd) or a bare "<name>" / "projects/<name>" form resolved against this
home's projects dir.

Exit code: 0. Per-clone outcomes are reported as lines, not as exit status -
one stuck clone must not hide the outcome of the others.

.EXAMPLE
./bin/fm-fleet-sync.ps1

.EXAMPLE
./bin/fm-fleet-sync.ps1 dotfiles-private
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmFleetSync'

try {
    foreach ($line in @(Invoke-FmFleetSync -Project $Project)) {
        [Console]::Out.Write("$line`n")
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
