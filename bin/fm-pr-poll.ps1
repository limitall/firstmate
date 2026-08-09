# bin/fm-pr-poll.ps1 - static watcher program for a validated PR/MR poll sidecar.
#
# Twin: bin/fm-pr-poll.sh
#
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, INCLUDING on every error, so a failed lookup can never be read as a
# merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task. Each
# provider is read through its own standard CLI, gh for GitHub and glab for
# GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# CLI (both forms are the twin's):
#   fm-pr-poll.ps1 --validated <provider> <url> <host> <path> <number>
#   fm-pr-poll.ps1                    # sidecar derived from this file's own name
#
# Always exits 0. Any other argument shape exits 0 silently.
#
# ---------------------------------------------------------------------------
# THIS FILE IS NEVER PUBLISHED AS A CHECK, AND THE SIDECAR BRANCH IS THEREFORE
# UNREACHABLE IN PRACTICE
#
# bin/fm-pr-check.ps1 arms every poll with bin/fm-pr-poll.SH, because the
# published bytes and their recorded SHA-256 must be identical in both language
# trees while both are live against one state directory (see that file's header,
# and contract 2 in docs/powershell-port.md). A PowerShell watcher therefore
# reaches this file only through `--validated`, which is also the only form
# bin/fm-watch.sh uses today.
#
# The `$0`-derived branch is ported anyway, because the CLI surface is part of
# the contract (contract 4) and because a file that quietly dropped a documented
# argument shape would be a silent divergence. It cannot be exercised
# differentially: pwsh will not run a script whose name ends in .check.sh, which
# is the only name that branch responds to. That gap is recorded here rather
# than papered over.
#
# ---------------------------------------------------------------------------
# THE VALIDATION IS INLINE ON PURPOSE - IT IS NOT A MISSED REUSE OPPORTUNITY
#
# bin/fm-pr-lib.psm1 has Test-FmPrGitlabHost, Test-FmPrGitlabPath and
# Read-FmPrFixedRecord, and this file uses none of them. Two reasons, both
# load-bearing:
#
#   1. The rules are DELIBERATELY DIFFERENT. The lib's host gate enforces
#      per-label length and hyphen rules; the poll's does not (it checks only
#      leading/trailing dot, a doubled dot, and the character class). Calling the
#      lib here would make the poll STRICTER than its bash twin, so a merge
#      request on a host the bash poll follows would silently stop being polled.
#   2. The bash twin is byte-static and depends on nothing. Its whole security
#      argument is that the poll re-derives every component itself and refuses
#      unless the stored URL is exactly reconstructible from them, so a doctored
#      sidecar cannot redirect it. Reproducing that means reproducing the
#      independence, not just the verdicts.
#
# Only bin/fm-common.psm1 is imported, for the sanctioned stdout writer and the
# exit discipline.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

# The `exec 3< file` + five `IFS= read -r` twin, with the same refusals: a field
# that is not newline-terminated fails `read` and refuses the record, and a SIXTH
# terminated line refuses it too. Latin-1 so every byte round-trips to one char.
function Read-FmPollSidecar {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $text = ''
    try {
        $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($Path))
    } catch {
        return $null
    }
    $parts = @($text.Split("`n"))
    # The final element is what follows the last LF: empty when the file ended
    # with one, otherwise an UNTERMINATED fragment that `read` would fail on.
    $terminated = $parts.Length - 1
    if ($terminated -lt 5) { return $null }
    # A sixth terminated line is the `if IFS= read -r _extra` guard firing.
    if ($terminated -gt 5) { return $null }
    return , @($parts[0..4])
}

# `command -v <tool>` plus the resolved path in one step: Process.Start appends
# only ".exe" to a bare name, so a tool published with any other PATHEXT
# extension has to be resolved through Get-Command to be runnable at all.
function Resolve-FmPollTool {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

Invoke-FmMain -UnexpectedCode 0 {
    $provider = ''
    $url = ''
    $forgeHost = ''
    $projectPath = ''
    $number = ''

    if ($fmArgv.Count -eq 6 -and [string]::Equals([string]$fmArgv[0], '--validated', [System.StringComparison]::Ordinal)) {
        $provider = [string]$fmArgv[1]
        $url = [string]$fmArgv[2]
        $forgeHost = [string]$fmArgv[3]
        $projectPath = [string]$fmArgv[4]
        $number = [string]$fmArgv[5]
    } elseif ($fmArgv.Count -eq 0) {
        $self = [string]$PSCommandPath
        if (-not $self.EndsWith('.check.sh', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        $data = $self.Substring(0, $self.Length - '.check.sh'.Length) + '.pr-poll'
        $native = ConvertTo-FmNativePath $data
        if (-not [System.IO.File]::Exists($native) -or (Test-FmSymlink -Path $native)) { Exit-FmScript 0 }
        $fields = Read-FmPollSidecar -Path $native
        if ($null -eq $fields) { Exit-FmScript 0 }
        $provider = $fields[0]
        $url = $fields[1]
        $forgeHost = $fields[2]
        $projectPath = $fields[3]
        $number = $fields[4]
    } else {
        Exit-FmScript 0
    }

    # `case "$number" in [1-9]*)` then `*[!0-9]*)`: a positive decimal with no
    # leading zero and nothing else.
    if (-not [regex]::IsMatch($number, '\A[1-9][0-9]*\z')) { Exit-FmScript 0 }

    # Every component is revalidated here rather than trusted from the sidecar,
    # and the stored URL must then be exactly reconstructible from those
    # components, so a doctored sidecar cannot redirect this poll at another host
    # or project.
    if ([string]::Equals($provider, 'github', [System.StringComparison]::Ordinal)) {
        if (-not [string]::Equals($forgeHost, 'github.com', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        $slash = $projectPath.IndexOf('/')
        # ${path%%/*} and ${path#*/}: with no slash at all both expansions yield
        # the whole string, and the repository then fails its own class check
        # only if it holds one - so the no-slash case is reproduced literally.
        $owner = if ($slash -lt 0) { $projectPath } else { $projectPath.Substring(0, $slash) }
        $repo = if ($slash -lt 0) { $projectPath } else { $projectPath.Substring($slash + 1) }
        if ($owner.Length -lt 1 -or $owner.Length -gt 39) { Exit-FmScript 0 }
        if (-not [regex]::IsMatch($owner, '\A[A-Za-z0-9-]+\z')) { Exit-FmScript 0 }
        if ($owner.StartsWith('-', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($owner.EndsWith('-', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($owner.Contains('--', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($repo.Length -lt 1 -or $repo.Length -gt 100) { Exit-FmScript 0 }
        if ([string]::Equals($repo, '.', [System.StringComparison]::Ordinal) -or
            [string]::Equals($repo, '..', [System.StringComparison]::Ordinal)) {
            Exit-FmScript 0
        }
        if (-not [regex]::IsMatch($repo, '\A[A-Za-z0-9._-]+\z')) { Exit-FmScript 0 }
        if (-not [string]::Equals($url, "https://$forgeHost/$owner/$repo/pull/$number", [System.StringComparison]::Ordinal)) {
            Exit-FmScript 0
        }
        $gh = Resolve-FmPollTool 'gh'
        if ($null -eq $gh) { Exit-FmScript 0 }
        $view = Invoke-FmTool -FilePath $gh -Arguments @('pr', 'view', $url, '--json', 'state', '-q', '.state')
        if (-not $view.Ok) { Exit-FmScript 0 }
        # `$( )` strips trailing newlines and nothing else.
        if ([string]::Equals($view.StdOut.TrimEnd("`n"), 'MERGED', [System.StringComparison]::Ordinal)) {
            Write-FmOut 'merged'
        }
        Exit-FmScript 0
    }

    if ([string]::Equals($provider, 'gitlab', [System.StringComparison]::Ordinal)) {
        if ($forgeHost.Length -lt 1 -or $forgeHost.Length -gt 253) { Exit-FmScript 0 }
        if ([string]::Equals($forgeHost, 'github.com', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($forgeHost.StartsWith('.', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($forgeHost.EndsWith('.', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($forgeHost.Contains('..', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if (-not [regex]::IsMatch($forgeHost, '\A[a-z0-9.-]+\z')) { Exit-FmScript 0 }
        if ($projectPath.Length -lt 3 -or $projectPath.Length -gt 1024) { Exit-FmScript 0 }
        if ($projectPath.StartsWith('/', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($projectPath.EndsWith('/', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
        if ($projectPath.Contains('//', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }

        # A GitLab project sits under at least one group at no fixed depth, and
        # GitLab reserves the "-" segment as its route separator.
        $segments = @($projectPath.Split('/'))
        if ($segments.Count -gt 20) { Exit-FmScript 0 }
        foreach ($segment in $segments) {
            if ($segment.Length -lt 1 -or $segment.Length -gt 255) { Exit-FmScript 0 }
            if ([string]::Equals($segment, '.', [System.StringComparison]::Ordinal) -or
                [string]::Equals($segment, '..', [System.StringComparison]::Ordinal)) {
                Exit-FmScript 0
            }
            if ($segment.StartsWith('-', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
            if ($segment.EndsWith('.git', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
            if ($segment.EndsWith('.atom', [System.StringComparison]::Ordinal)) { Exit-FmScript 0 }
            if (-not [regex]::IsMatch($segment, '\A[A-Za-z0-9._-]+\z')) { Exit-FmScript 0 }
        }
        if ($segments.Count -lt 2) { Exit-FmScript 0 }
        if (-not [string]::Equals($url, "https://$forgeHost/$projectPath/-/merge_requests/$number", [System.StringComparison]::Ordinal)) {
            Exit-FmScript 0
        }
        # glab resolves the instance from the project URL passed to -R, so the
        # host comes from the validated record rather than glab's configured
        # default. It cannot take a merge request URL the way gh does: that form
        # shells out to git for the current repository, and the watcher runs in
        # no repository. The state is read from glab's own field output rather
        # than its JSON, because plain glab has no field selector and firstmate
        # does not require a JSON processor; only an exact "merged" wakes, so a
        # changed format or an unreadable merge request stays silent instead of
        # reporting a merge.
        $glab = Resolve-FmPollTool 'glab'
        if ($null -eq $glab) { Exit-FmScript 0 }
        $view = Invoke-FmTool -FilePath $glab -Arguments @('mr', 'view', $number, '-R', "https://$forgeHost/$projectPath")
        if (-not $view.Ok) { Exit-FmScript 0 }
        # `sed -n 's/^state:[[:space:]]*//p' | head -1`: the first line beginning
        # `state:`, with the run of blanks after the colon removed.
        foreach ($line in $view.StdOut.Split("`n")) {
            if (-not $line.StartsWith('state:', [System.StringComparison]::Ordinal)) { continue }
            $value = $line.Substring(6).TrimStart(" `t`r`n`v`f".ToCharArray())
            if ([string]::Equals($value, 'merged', [System.StringComparison]::Ordinal)) { Write-FmOut 'merged' }
            break
        }
        Exit-FmScript 0
    }

    Exit-FmScript 0
}
