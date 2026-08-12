#requires -Version 7.0
<#
.SYNOPSIS
fm-ensure-agents-md.ps1 - ensure a project worktree follows the agent-memory
file convention.

.DESCRIPTION
Port of bin/fm-ensure-agents-md.sh. AGENTS.md is the real project-intrinsic
knowledge file; CLAUDE.md carries the same content under the name a Claude
session looks for. Creates a minimal AGENTS.md skeleton when neither file
exists, promotes a real CLAUDE.md when it is the only file present, injects the
canonical "## Maintaining this file" section idempotently, and refuses to
clobber distinct real files or a wrong link.

Where the host does not allow creating a symlink - stock Windows without
Developer Mode - CLAUDE.md is created as a hardlink, or as a copy that is
re-synced on later runs. What was actually created is always named in the
output, so a copy is never reported as a link.

This is a worktree utility for crewmates, not a supervision script, so it does
not call the guard.

Exit codes: 0 done, 1 conflict or failure, 2 usage.

.EXAMPLE
./bin/fm-ensure-agents-md.ps1 .
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [ValidateSet('Auto', 'Symlink', 'HardLink', 'Copy')][string]$LinkStrategy = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Set-FmAgentsMemory'

try {
    $result = Set-FmAgentsMemory -Path $Path -LinkStrategy $LinkStrategy
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
